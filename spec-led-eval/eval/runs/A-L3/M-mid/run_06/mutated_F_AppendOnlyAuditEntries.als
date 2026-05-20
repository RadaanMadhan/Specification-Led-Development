// === feature_model.als — Alloy model for FCA-Regulated Loan Application (A-L3) ===
// Feature branch: 005-fca-loan-applications
// Encodes invariants from spec.md, data-model.md, and contracts/http-api.md

// ---------------------------------------------------------------------------
// ROLES
// ---------------------------------------------------------------------------
abstract sig Role {}
one sig RApplicant, ROfficer, RAuditor, RSystem extends Role {}

// ---------------------------------------------------------------------------
// USERS
// ---------------------------------------------------------------------------
sig User {
  userRoles : set Role
}

// ---------------------------------------------------------------------------
// APPLICATION STATUS
// ---------------------------------------------------------------------------
abstract sig AppStatus {}
one sig Pending, UnderReview, Approved, Rejected extends AppStatus {}

// ---------------------------------------------------------------------------
// PURPOSE (fixed list from FR-007)
// ---------------------------------------------------------------------------
abstract sig Purpose {}
one sig HomeImprovement, DebtConsolidation, Vehicle, Education,
         Medical, Wedding, Holiday, Business, Other extends Purpose {}

// ---------------------------------------------------------------------------
// LOAN APPLICATION
// ---------------------------------------------------------------------------
sig LoanApplication {
  appApplicant : one User,
  appOfficer   : lone User,   // NULL in the "no eligible officer" edge case
  appStatus    : one AppStatus,
  appPurpose   : one Purpose
}

// ---------------------------------------------------------------------------
// AUDIT ENTRY  (append-only, chained, immutable — FR-018)
// ---------------------------------------------------------------------------
sig AuditEntry {
  auditApp        : one LoanApplication,
  auditActor      : one User,
  auditActorRole  : one Role,
  auditPrevStatus : lone AppStatus,   // none for the initial (none)→pending entry
  auditNewStatus  : one AppStatus
}

// ---------------------------------------------------------------------------
// OPERATIONS (HTTP requests reaching business logic)
// ---------------------------------------------------------------------------
abstract sig OperationKind {}
one sig PostApps, GetAppById, PatchStatus, GetAudit extends OperationKind {}

abstract sig Outcome {}
one sig Success, Denied extends Outcome {}

sig Operation {
  opKind       : one OperationKind,
  opCaller     : one User,
  opCallerRole : one Role,             // the role under which the caller acts
  opTarget     : lone LoanApplication, // the application this op addresses (if any)
  opOutcome    : one Outcome
}

// ---------------------------------------------------------------------------
// PERMISSION MATRIX  (base role × operation — FR-003/004/005, contracts/)
// ---------------------------------------------------------------------------
one sig PermMatrix {
  Allowed : set Role -> OperationKind
}

// ---------------------------------------------------------------------------
// FACT: non-empty universe (prevent vacuous universal quantification)
// ---------------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
}

// ---------------------------------------------------------------------------
// FACT: permission matrix — canonical "allow" cells from contracts/http-api.md
//   PostApps:   Applicant ✅, Officer ❌, Auditor ❌, System ❌
//   GetAppById: Applicant ✅ (ownership-conditional), Officer ✅ (assignment-cond),
//               Auditor ✅ (unconditional)  → all three in base matrix
//   PatchStatus: Officer ✅ (further constrained by FR-012/FR-013), others ❌
//   GetAudit:   Auditor ✅ (FR-023), others ❌
// ---------------------------------------------------------------------------
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (RApplicant -> PostApps)   +
    (RApplicant -> GetAppById) +
    (ROfficer   -> GetAppById) +
    (RAuditor   -> GetAppById) +
    (ROfficer   -> PatchStatus)+
    (RAuditor   -> GetAudit)
}

// FACT: every caller acts under a role they actually hold (FR-002)
fact F_CallerRoleConsistency {
  all op : Operation | op.opCallerRole in op.opCaller.userRoles
}

// FACT: role mutual exclusivity — a user may not hold both Officer and Auditor (FR-002)
fact F_RoleMutualExclusivity {
  all u : User | not (ROfficer in u.userRoles and RAuditor in u.userRoles)
}

// FACT: every application's applicant holds the Applicant role (FR-006)
fact F_ApplicantRoleRequired {
  all a : LoanApplication | RApplicant in a.appApplicant.userRoles
}

// FACT: when an officer is assigned, they hold the Officer role (FR-010)
fact F_AssignedOfficerHoldsOfficerRole {
  all a : LoanApplication |
    some a.appOfficer implies ROfficer in a.appOfficer.userRoles
}

// FACT: no self-assignment — assigned officer ≠ applicant (FR-011)
fact F_NoSelfAssignment {
  all a : LoanApplication |
    some a.appOfficer implies a.appOfficer != a.appApplicant
}

// FACT: no self-approval — a PatchStatus operation that succeeds must not have
//       the caller being the same user as the application's applicant (FR-013)
fact F_NoSelfApproval {
  all op : Operation |
    (op.opKind = PatchStatus and op.opOutcome = Success and some op.opTarget)
      implies op.opCaller != op.opTarget.appApplicant
}

// FACT: only the assigned officer may successfully PatchStatus (FR-012)
fact F_OnlyAssignedOfficerPatches {
  all op : Operation |
    (op.opKind = PatchStatus and op.opOutcome = Success and some op.opTarget)
      implies (some op.opTarget.appOfficer and op.opCaller = op.opTarget.appOfficer)
}

// FACT: terminal states are immutable — no successful PatchStatus on Approved/Rejected app
//       (FR-015)
fact F_TerminalStateImmutable {
  all op : Operation |
    (op.opKind = PatchStatus and op.opOutcome = Success and some op.opTarget)
      implies op.opTarget.appStatus not in (Approved + Rejected)
}

// FACT: one in-flight application per applicant — no two distinct applications
//       for the same applicant are simultaneously Pending or UnderReview (FR-008)
fact F_OneInFlightPerApplicant {
  all disj a1, a2 : LoanApplication |
    a1.appApplicant = a2.appApplicant implies
      not (a1.appStatus in (Pending + UnderReview) and
           a2.appStatus in (Pending + UnderReview))
}

// FACT: audit completeness — every application has at least one audit entry (FR-016)
fact F_AuditCompleteness {
  all a : LoanApplication | some ae : AuditEntry | ae.auditApp = a
}

// FACT: initial audit entry exists — there is an entry with no previous status
//       and newStatus = Pending for every application (FR-016, data-model.md)
fact F_InitialAuditEntryExists {
  all a : LoanApplication |
    some ae : AuditEntry |
      ae.auditApp = a and no ae.auditPrevStatus and ae.auditNewStatus = Pending
}

// FACT: audit entry actor role is consistent with the actor's actual roles (FR-016)
fact F_AuditAttributionConsistency {
  all ae : AuditEntry |
    ae.auditActorRole in ae.auditActor.userRoles
}

// FACT: append-only audit log — no two distinct AuditEntries for the same
//       application record an identical (prevStatus, newStatus) transition;
//       since each status transition in the FSM can occur at most once per
//       application lifecycle, a duplicate pair would represent a mutation/replay
//       (FR-018; data-model.md "no UPDATE/DELETE on audit_entries")
fact F_AppendOnlyAuditEntries { /* MUTATED — body cleared by validator */ }

// FACT: valid status transitions only — audit entries record only the five
//       legal arcs of the FSM (FR-009, data-model.md state-machine table)
fact F_ValidTransitions {
  all ae : AuditEntry | {
    // Initial submission: (none) → pending
    (no ae.auditPrevStatus and ae.auditNewStatus = Pending)
    or
    // pending → under_review
    (ae.auditPrevStatus = Pending    and ae.auditNewStatus = UnderReview)
    or
    // under_review → approved
    (ae.auditPrevStatus = UnderReview and ae.auditNewStatus = Approved)
    or
    // under_review → rejected
    (ae.auditPrevStatus = UnderReview and ae.auditNewStatus = Rejected)
  }
}

// FACT: no-op transitions forbidden — previous ≠ new (data-model.md CHECK)
fact F_NoNoOpTransition {
  all ae : AuditEntry | some ae.auditPrevStatus implies ae.auditPrevStatus != ae.auditNewStatus
}

// FACT: null prevStatus iff newStatus = Pending (data-model.md CHECK constraint)
fact F_NullPrevStatusIffInitial {
  all ae : AuditEntry |
    (no ae.auditPrevStatus) iff (ae.auditNewStatus = Pending)
}

// FACT: base LeastPrivilege — a successful operation's caller role must appear
//       in the permission matrix for that operation kind (FR-003/004/005)
fact F_BaseLeastPrivilege {
  all op : Operation |
    op.opOutcome = Success implies
      (op.opCallerRole -> op.opKind) in PermMatrix.Allowed
}

// FACT: applicant's GET is ownership-conditional — an applicant caller may
//       only successfully GET an application they own (FR-003, FR-020)
fact F_OwnershipBasedGetAccess {
  all op : Operation |
    (op.opKind = GetAppById and op.opCallerRole = RApplicant and
     op.opOutcome = Success and some op.opTarget)
      implies op.opCaller = op.opTarget.appApplicant
}

// FACT: officer's GET is assignment-conditional — an officer caller (not auditor)
//       may only successfully GET an application assigned to them (FR-004)
fact F_AssignmentBasedGetAccess {
  all op : Operation |
    (op.opKind = GetAppById and op.opCallerRole = ROfficer and
     op.opOutcome = Success and some op.opTarget)
      implies op.opCaller = op.opTarget.appOfficer
}

// FACT: GetAudit is auditor-only — any successful GetAudit caller holds Auditor
//       (FR-023)
fact F_AuditEndpointAuditorOnly {
  all op : Operation |
    (op.opKind = GetAudit and op.opOutcome = Success)
      implies op.opCallerRole = RAuditor
}

// FACT: NoInformationLeakage — an applicant denied access to a GET cannot
//       distinguish "exists but not mine" from "does not exist."
//       Modeled structurally: every non-owner, non-officer, non-auditor GET
//       is Denied, regardless of whether a target app actually exists (FR-020/021).
fact F_NoInformationLeakage {
  all op : Operation |
    (op.opKind = GetAppById and
     op.opCallerRole = RApplicant and
     some op.opTarget and
     op.opCaller != op.opTarget.appApplicant)
      implies op.opOutcome = Denied
}

// FACT: auditor cannot write — PostApps and PatchStatus always Denied for Auditor
//       (FR-005, SC-007)
fact F_AuditorReadOnly {
  all op : Operation |
    op.opCallerRole = RAuditor implies
      op.opKind not in (PostApps + PatchStatus) or op.opOutcome = Denied
}

// FACT: applicant cannot PATCH status (FR-003, FR-024)
fact F_ApplicantCannotPatch {
  all op : Operation |
    (op.opKind = PatchStatus and op.opCallerRole = RApplicant)
      implies op.opOutcome = Denied
}

// FACT: auth required everywhere — every successful operation must be performed
//       by a user who holds at least one non-system role (FR-001)
fact F_AuthRequiredEverywhere {
  all op : Operation |
    op.opOutcome = Success implies
      (RApplicant in op.opCaller.userRoles or
       ROfficer   in op.opCaller.userRoles or
       RAuditor   in op.opCaller.userRoles)
}

// FACT: PostApps always targets no existing application (creates a new one)
fact F_PostAppsNoTarget {
  all op : Operation |
    op.opKind = PostApps implies no op.opTarget
}

// ===========================================================================
// PREDICATES & ASSERTIONS — one per pattern and one per FR
// ===========================================================================

// ---------------------------------------------------------------------------
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix;
//           spec.md FR-003/FR-004/FR-005
// ---------------------------------------------------------------------------
pred LeastPrivilege {
  some op : Operation | op.opOutcome = Success
  all op : Operation |
    op.opOutcome = Success implies
      (op.opCallerRole -> op.opKind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// ---------------------------------------------------------------------------
// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
// ---------------------------------------------------------------------------
pred PermissionCompleteness {
  // Every (Role × OperationKind) pair is either explicitly allowed or implicitly denied.
  // The allowed set is fully enumerated; the closed world covers all pairs.
  PermMatrix.Allowed =
    (RApplicant -> PostApps)   +
    (RApplicant -> GetAppById) +
    (ROfficer   -> GetAppById) +
    (RAuditor   -> GetAppById) +
    (ROfficer   -> PatchStatus)+
    (RAuditor   -> GetAudit)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// ---------------------------------------------------------------------------
// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-003/FR-004/FR-005;
//           contracts/http-api.md permission tables
// ---------------------------------------------------------------------------
pred PermissionGrounding {
  // Every allowed (Role,Op) pair has a grounding: it is one of the six
  // explicitly documented allow cells — no silent grants exist.
  some op : Operation | op.opOutcome = Success
  PermMatrix.Allowed in
    (RApplicant -> PostApps)   +
    (RApplicant -> GetAppById) +
    (ROfficer   -> GetAppById) +
    (RAuditor   -> GetAppById) +
    (ROfficer   -> PatchStatus)+
    (RAuditor   -> GetAudit)
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 5

// ---------------------------------------------------------------------------
// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md role descriptions;
//           contracts/http-api.md — Auditor read ⊇ Officer read ⊇ Applicant read
// ---------------------------------------------------------------------------
pred PrivilegeMonotonicity {
  // Auditor's read permissions are a superset of Officer's and Applicant's
  // for GetAppById (auditor sees any, officer sees assigned, applicant sees own).
  (RAuditor -> GetAppById) in PermMatrix.Allowed
  (ROfficer -> GetAppById) in PermMatrix.Allowed
  // Auditor may GetAudit; neither Officer nor Applicant may.
  (RAuditor -> GetAudit)  in PermMatrix.Allowed
  (ROfficer -> GetAudit)  not in PermMatrix.Allowed
  (RApplicant -> GetAudit) not in PermMatrix.Allowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 5

// ---------------------------------------------------------------------------
// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md
//           "Authentication (all endpoints)" section
// ---------------------------------------------------------------------------
pred AuthRequiredEverywhere {
  some op : Operation | op.opOutcome = Success
  all op : Operation |
    op.opOutcome = Success implies
      (RApplicant in op.opCaller.userRoles or
       ROfficer   in op.opCaller.userRoles or
       RAuditor   in op.opCaller.userRoles)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// ---------------------------------------------------------------------------
// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016/FR-017;
//           data-model.md UNIQUE + append constraints
// ---------------------------------------------------------------------------
pred AuditCompleteness {
  some LoanApplication
  // Every application has at least one audit entry.
  all a : LoanApplication | (some ae : AuditEntry | ae.auditApp = a)
  // Every application has exactly one initial audit entry (none→pending).
  all a : LoanApplication |
    (one ae : AuditEntry | ae.auditApp = a and no ae.auditPrevStatus and ae.auditNewStatus = Pending)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// ---------------------------------------------------------------------------
// PATTERN: AppendOnly  ANCHOR: spec.md FR-018/FR-019;
//           data-model.md "no UPDATE/DELETE on audit_entries"
// ---------------------------------------------------------------------------
pred AppendOnly {
  some AuditEntry
  // No two distinct entries for the same application share a (prevStatus, newStatus) pair —
  // a duplicate pair is the fingerprint of an in-place update / replay.
  all disj ae1, ae2 : AuditEntry |
    ae1.auditApp = ae2.auditApp implies
      (ae1.auditPrevStatus != ae2.auditPrevStatus or
       ae1.auditNewStatus  != ae2.auditNewStatus)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// ---------------------------------------------------------------------------
// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016;
//           data-model.md AuditEntry.actor_id / actor_role fields
// ---------------------------------------------------------------------------
pred AttributionCorrectness {
  some AuditEntry
  all ae : AuditEntry | ae.auditActorRole in ae.auditActor.userRoles
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ---------------------------------------------------------------------------
// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md LoanApplication.applicant_id
//           (NOT NULL FK); spec.md "each Application is owned by exactly one applicant"
// ---------------------------------------------------------------------------
pred OwnershipExclusivity {
  some LoanApplication
  all a : LoanApplication | one a.appApplicant
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// ---------------------------------------------------------------------------
// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003/FR-004;
//           contracts/http-api.md GET permission table
// ---------------------------------------------------------------------------
pred OwnershipBasedAccess {
  some op : Operation | op.opKind = GetAppById and op.opOutcome = Success
  // Applicant can only see own applications.
  all op : Operation |
    (op.opKind = GetAppById and op.opCallerRole = RApplicant and
     op.opOutcome = Success and some op.opTarget)
      implies op.opCaller = op.opTarget.appApplicant
  // Officer can only see their assigned application.
  all op : Operation |
    (op.opKind = GetAppById and op.opCallerRole = ROfficer and
     op.opOutcome = Success and some op.opTarget)
      implies op.opCaller = op.opTarget.appOfficer
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// ---------------------------------------------------------------------------
// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020/FR-021/FR-022;
//           contracts/http-api.md "Byte-equivalent not-found response"
// ---------------------------------------------------------------------------
pred NoInformationLeakage {
  some op : Operation | op.opKind = GetAppById and op.opOutcome = Denied
  // A non-owner applicant always gets Denied — existence of the target app
  // is invisible regardless of whether the app is real.
  all op : Operation |
    (op.opKind = GetAppById and op.opCallerRole = RApplicant and
     some op.opTarget and op.opCaller != op.opTarget.appApplicant)
      implies op.opOutcome = Denied
  // A non-assigned officer always gets Denied for GET.
  all op : Operation |
    (op.opKind = GetAppById and op.opCallerRole = ROfficer and
     some op.opTarget and op.opCaller != op.opTarget.appOfficer)
      implies op.opOutcome = Denied
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ---------------------------------------------------------------------------
// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-013; data-model.md
//           CHECK (assigned_officer_id != applicant_id)
// ---------------------------------------------------------------------------
pred NoSelfMutation {
  some op : Operation | op.opKind = PatchStatus and op.opOutcome = Success
  all op : Operation |
    (op.opKind = PatchStatus and op.opOutcome = Success and some op.opTarget)
      implies op.opCaller != op.opTarget.appApplicant
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// ---------------------------------------------------------------------------
// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-001/FR-017;
//           data-model.md atomicity contract
// ---------------------------------------------------------------------------
pred ValidationBeforeMutation {
  // If an operation outcome is Denied, there is no new AuditEntry attributed
  // to it. Modeled as: every AuditEntry's actor corresponds to a user who
  // was involved in a successful operation on that application.
  // Structural proxy: AuditEntries only exist for transitions that succeeded.
  some AuditEntry
  all ae : AuditEntry |
    some op : Operation |
      op.opOutcome = Success and
      op.opTarget = ae.auditApp and
      op.opCaller = ae.auditActor
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ===========================================================================
// FEATURE-SPECIFIC PREDICATES (FR coverage)
// ===========================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-002 — role mutual exclusivity (officer ∩ auditor = ∅)
pred FR_002_RoleMutualExclusivity {
  some User
  all u : User | not (ROfficer in u.userRoles and RAuditor in u.userRoles)
}
assert FR_002_RoleMutualExclusivity { FR_002_RoleMutualExclusivity }
check FR_002_RoleMutualExclusivity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 — applicant cannot PATCH status
pred FR_003_ApplicantCannotPatch {
  some op : Operation | op.opCallerRole = RApplicant
  all op : Operation |
    (op.opKind = PatchStatus and op.opCallerRole = RApplicant)
      implies op.opOutcome = Denied
}
assert FR_003_ApplicantCannotPatch { FR_003_ApplicantCannotPatch }
check FR_003_ApplicantCannotPatch for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 — officer cannot PostApps (as officer role)
pred FR_004_OfficerCannotPost {
  some op : Operation | op.opCallerRole = ROfficer
  all op : Operation |
    (op.opKind = PostApps and op.opCallerRole = ROfficer)
      implies op.opOutcome = Denied
}
assert FR_004_OfficerCannotPost { FR_004_OfficerCannotPost }
check FR_004_OfficerCannotPost for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 — auditor is read-only (cannot PostApps or PatchStatus)
pred FR_005_AuditorReadOnly {
  some op : Operation | op.opCallerRole = RAuditor
  all op : Operation |
    op.opCallerRole = RAuditor implies
      (op.opKind not in (PostApps + PatchStatus) or op.opOutcome = Denied)
}
assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 — at most one in-flight application per applicant
pred FR_008_OneInFlightPerApplicant {
  some LoanApplication
  all disj a1, a2 : LoanApplication |
    a1.appApplicant = a2.appApplicant implies
      not (a1.appStatus in (Pending + UnderReview) and
           a2.appStatus in (Pending + UnderReview))
}
assert FR_008_OneInFlightPerApplicant { FR_008_OneInFlightPerApplicant }
check FR_008_OneInFlightPerApplicant for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 — only valid FSM transitions appear in audit log
pred FR_009_ValidTransitions {
  some AuditEntry
  all ae : AuditEntry | {
    (no ae.auditPrevStatus and ae.auditNewStatus = Pending)
    or
    (ae.auditPrevStatus = Pending     and ae.auditNewStatus = UnderReview)
    or
    (ae.auditPrevStatus = UnderReview and ae.auditNewStatus = Approved)
    or
    (ae.auditPrevStatus = UnderReview and ae.auditNewStatus = Rejected)
  }
}
assert FR_009_ValidTransitions { FR_009_ValidTransitions }
check FR_009_ValidTransitions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 — assigned officer ≠ applicant (no self-assignment)
pred FR_011_NoSelfAssignment {
  some LoanApplication
  all a : LoanApplication |
    some a.appOfficer implies a.appOfficer != a.appApplicant
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 — only assigned officer can successfully PatchStatus
pred FR_012_OnlyAssignedOfficerPatches {
  some op : Operation | op.opKind = PatchStatus and op.opOutcome = Success
  all op : Operation |
    (op.opKind = PatchStatus and op.opOutcome = Success and some op.opTarget)
      implies (some op.opTarget.appOfficer and op.opCaller = op.opTarget.appOfficer)
}
assert FR_012_OnlyAssignedOfficerPatches { FR_012_OnlyAssignedOfficerPatches }
check FR_012_OnlyAssignedOfficerPatches for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 — no self-approval (officer cannot decide own application)
pred FR_013_NoSelfApproval {
  some op : Operation | op.opKind = PatchStatus and op.opOutcome = Success
  all op : Operation |
    (op.opKind = PatchStatus and op.opOutcome = Success and some op.opTarget)
      implies op.opCaller != op.opTarget.appApplicant
}
assert FR_013_NoSelfApproval { FR_013_NoSelfApproval }
check FR_013_NoSelfApproval for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 — terminal states (Approved/Rejected) are immutable
pred FR_015_TerminalStateImmutable {
  some op : Operation | op.opKind = PatchStatus
  all op : Operation |
    (op.opKind = PatchStatus and op.opOutcome = Success and some op.opTarget)
      implies op.opTarget.appStatus not in (Approved + Rejected)
}
assert FR_015_TerminalStateImmutable { FR_015_TerminalStateImmutable }
check FR_015_TerminalStateImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 — every application has an initial audit entry
pred FR_016_InitialAuditEntry {
  some LoanApplication
  all a : LoanApplication |
    (some ae : AuditEntry |
      ae.auditApp = a and no ae.auditPrevStatus and ae.auditNewStatus = Pending)
}
assert FR_016_InitialAuditEntry { FR_016_InitialAuditEntry }
check FR_016_InitialAuditEntry for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 — audit log is append-only (no duplicate transitions)
pred FR_018_AuditImmutable {
  some AuditEntry
  all disj ae1, ae2 : AuditEntry |
    ae1.auditApp = ae2.auditApp implies
      not (ae1.auditPrevStatus = ae2.auditPrevStatus and
           ae1.auditNewStatus  = ae2.auditNewStatus)
}
assert FR_018_AuditImmutable { FR_018_AuditImmutable }
check FR_018_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-023 — GetAudit is exclusively for Auditor role
pred FR_023_AuditEndpointAuditorOnly {
  some op : Operation | op.opKind = GetAudit and op.opOutcome = Success
  all op : Operation |
    (op.opKind = GetAudit and op.opOutcome = Success)
      implies op.opCallerRole = RAuditor
}
assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-024 — applicant cannot modify application fields post-submission
pred FR_024_ApplicantCannotModifyPostSubmission {
  some op : Operation | op.opCallerRole = RApplicant
  // The only write action an applicant can take is PostApps.
  // PatchStatus for applicant role is always Denied.
  all op : Operation |
    (op.opCallerRole = RApplicant and op.opOutcome = Success)
      implies op.opKind = PostApps or op.opKind = GetAppById
}
assert FR_024_ApplicantCannotModifyPostSubmission { FR_024_ApplicantCannotModifyPostSubmission }
check FR_024_ApplicantCannotModifyPostSubmission for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001 — auth required; unauthenticated = no role
//   Modeled as: successful ops are only performed by users holding a real role
pred FR_001_AuthRequired {
  some op : Operation | op.opOutcome = Success
  all op : Operation |
    op.opOutcome = Success implies
      (RApplicant in op.opCaller.userRoles or
       ROfficer   in op.opCaller.userRoles or
       RAuditor   in op.opCaller.userRoles)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 — null-prev-status iff initial entry
//   (data-model.md CHECK (previous_status IS NULL) = (new_status = 'pending'))
pred FR_002_NullPrevIffInitial {
  some AuditEntry
  all ae : AuditEntry |
    (no ae.auditPrevStatus) iff (ae.auditNewStatus = Pending)
}
assert FR_002_NullPrevIffInitial { FR_002_NullPrevIffInitial }
check FR_002_NullPrevIffInitial for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 — when assigned_officer is set, must differ from applicant
pred FR_010_AssignmentExcludesApplicant {
  some a : LoanApplication | some a.appOfficer
  all a : LoanApplication |
    some a.appOfficer implies a.appOfficer != a.appApplicant
}
assert FR_010_AssignmentExcludesApplicant { FR_010_AssignmentExcludesApplicant }
check FR_010_AssignmentExcludesApplicant for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AppendOnlyViolation { some disj ae1, ae2 : AuditEntry | ae1.auditApp = ae2.auditApp and ae1.auditPrevStatus = ae2.auditPrevStatus and ae1.auditNewStatus = ae2.auditNewStatus }
