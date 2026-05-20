// === feature_model.als — Alloy 6 model for FCA-Regulated Loan Application (A-L3) ===
//
// Feature branch : 005-fca-loan-applications
// Artefacts used : spec.md, data-model.md, contracts/http-api.md
// Generated for  : automated check pipeline (java -jar alloy.jar exec feature_model.als)
//
// Structural overview
//   Sigs   : Role, AppStatus, OperationKind, User, LoanApplication, AuditEntry, Operation
//   Statics: PermMatrix (singleton permission table)
//   Facts  : F_* — named, removal-testable constraints
//   Preds  : one per pattern / per FR; each has a matching assert + check


// ══════════════════════════════════════════════════════════════════
// Enumeration sigs
// ══════════════════════════════════════════════════════════════════

abstract sig Role {}
one sig RApplicant, ROfficer, RAuditor, RSystem extends Role {}

abstract sig AppStatus {}
one sig Pending, UnderReview, Approved, Rejected extends AppStatus {}

abstract sig OperationKind {}
one sig PostApplications, GetApplicationById,
        PatchApplicationStatus, GetApplicationAudit extends OperationKind {}

abstract sig Outcome {}
one sig Success, Failure extends Outcome {}


// ══════════════════════════════════════════════════════════════════
// Permission matrix — singleton field (contracts/http-api.md §Permission matrix)
// ══════════════════════════════════════════════════════════════════

one sig PermMatrix { Allowed: set Role -> OperationKind }


// ══════════════════════════════════════════════════════════════════
// Dynamic sigs
// ══════════════════════════════════════════════════════════════════

sig User {
  userRoles: some Role   // at least one; RSystem is structurally excluded below
}

sig LoanApplication {
  appApplicant:    one  User,
  assignedOfficer: lone User,   // lone = nullable; null in "no eligible officer" edge case
  appStatus:       one  AppStatus
}

// AuditEntry — append-only record of one state transition
sig AuditEntry {
  entryApp:        one  LoanApplication,
  entryActor:      one  User,            // "system" sentinel modeled as a special User atom
  entryActorRole:  one  Role,
  entryPrevStatus: lone AppStatus,       // lone = nullable; null only for initial submission entry
  entryNewStatus:  one  AppStatus
}

// Operation — one API call (success or failure)
sig Operation {
  opCaller:  one  User,
  opKind:    one  OperationKind,
  opTarget:  lone LoanApplication,      // lone — audit endpoint has a target too
  opOutcome: one  Outcome
}


// ══════════════════════════════════════════════════════════════════
// F_NonEmptyUniverse — force at least one atom of every dynamic sig
// ══════════════════════════════════════════════════════════════════

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
}


// ══════════════════════════════════════════════════════════════════
// F_PermissionMatrix — closed-world permission table
// ANCHOR: contracts/http-api.md §Permission matrix
// ══════════════════════════════════════════════════════════════════

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (RApplicant -> PostApplications)       +
    (RApplicant -> GetApplicationById)     +
    (ROfficer   -> GetApplicationById)     +
    (ROfficer   -> PatchApplicationStatus) +
    (RAuditor   -> GetApplicationById)     +
    (RAuditor   -> GetApplicationAudit)
  // RSystem holds no direct operation privileges
}


// ══════════════════════════════════════════════════════════════════
// F_RoleMultiplicity — officer and auditor are mutually exclusive;
//   RSystem never appears in a real user's role set (FR-002)
// ══════════════════════════════════════════════════════════════════

fact F_RoleMultiplicity {
  all u: User |
    not (ROfficer in u.userRoles and RAuditor in u.userRoles)
  all u: User | RSystem not in u.userRoles
}


// ══════════════════════════════════════════════════════════════════
// F_OwnershipExclusivity — every application's applicant holds RApplicant;
//   assigned officer, if present, holds ROfficer (data-model.md FK rules)
// ══════════════════════════════════════════════════════════════════

fact F_OwnershipExclusivity {
  all a: LoanApplication | RApplicant in a.appApplicant.userRoles
  all a: LoanApplication |
    some a.assignedOfficer implies ROfficer in a.assignedOfficer.userRoles
}


// ══════════════════════════════════════════════════════════════════
// F_NoSelfAssignment — assigned officer ≠ applicant (FR-011,
//   data-model.md CHECK assigned_officer_id != applicant_id)
// ══════════════════════════════════════════════════════════════════

fact F_NoSelfAssignment {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.appApplicant
}


// ══════════════════════════════════════════════════════════════════
// F_OneInFlightPerApplicant — at most one pending/under_review per applicant (FR-008)
// ══════════════════════════════════════════════════════════════════

fact F_OneInFlightPerApplicant {
  all disj a1, a2: LoanApplication |
    a1.appApplicant = a2.appApplicant implies
    not (a1.appStatus in (Pending + UnderReview) and
         a2.appStatus in (Pending + UnderReview))
}


// ══════════════════════════════════════════════════════════════════
// F_ValidStatusTransitions — allowed transitions only (FR-009);
//   also enforces terminal-state finality (FR-015) by ruling out
//   Approved/Rejected as a source status in any audit entry.
// ══════════════════════════════════════════════════════════════════

fact F_ValidStatusTransitions {
  all e: AuditEntry | {
    // Initial entry: no prev ↔ new = Pending
    (no e.entryPrevStatus) iff (e.entryNewStatus = Pending)
    // Non-initial transitions: only Pending→UnderReview, UnderReview→{Approved,Rejected}
    some e.entryPrevStatus implies {
      (e.entryPrevStatus = Pending     implies e.entryNewStatus = UnderReview) and
      (e.entryPrevStatus = UnderReview implies e.entryNewStatus in (Approved + Rejected))
    }
    // No transition originates from a terminal state (FR-015)
    e.entryPrevStatus not in (Approved + Rejected)
  }
}


// ══════════════════════════════════════════════════════════════════
// F_AuditCompleteness — every application has at least one audit entry;
//   every application's current status matches the newStatus of some entry (FR-016/FR-017)
// ══════════════════════════════════════════════════════════════════

fact F_AuditCompleteness {
  all a: LoanApplication | {
    some e: AuditEntry | e.entryApp = a
    // The current status must be the newStatus of at least one audit entry for this app
    some e: AuditEntry | e.entryApp = a and e.entryNewStatus = a.appStatus
  }
}


// ══════════════════════════════════════════════════════════════════
// F_AppendOnlyAuditEntries — no two entries on the same application
//   share an identical (prevStatus, newStatus) pair (FR-018, append-only invariant)
// ══════════════════════════════════════════════════════════════════

fact F_AppendOnlyAuditEntries {
  // Exactly one initial entry per application (prev=null, new=Pending)
  all a: LoanApplication |
    lone e: AuditEntry | e.entryApp = a and no e.entryPrevStatus
  // No duplicate (prevStatus, newStatus) transitions per application
  all disj e1, e2: AuditEntry |
    e1.entryApp = e2.entryApp implies
    not (e1.entryPrevStatus = e2.entryPrevStatus and
         e1.entryNewStatus  = e2.entryNewStatus)
}


// ══════════════════════════════════════════════════════════════════
// F_AttributionCorrectness — audit entry actorRole ∈ actor's roles,
//   or actorRole = RSystem (system-actor sentinel) (FR-016)
// ══════════════════════════════════════════════════════════════════

fact F_AttributionCorrectness {
  all e: AuditEntry |
    e.entryActorRole != RSystem implies e.entryActorRole in e.entryActor.userRoles
}


// ══════════════════════════════════════════════════════════════════
// F_NoSelfApproval — a successful PATCH's caller ≠ the application's
//   applicant (FR-013, defence-in-depth at decision time)
// ══════════════════════════════════════════════════════════════════

fact F_NoSelfApproval { /* MUTATED — body cleared by validator */ }


// ══════════════════════════════════════════════════════════════════
// F_OnlyAssignedOfficerCanPatch — successful PATCH only when caller is
//   the application's assignedOfficer (FR-012)
// ══════════════════════════════════════════════════════════════════

fact F_OnlyAssignedOfficerCanPatch {
  all op: Operation |
    (op.opKind = PatchApplicationStatus and op.opOutcome = Success)
    implies (some a: LoanApplication |
               op.opTarget = a and a.assignedOfficer = op.opCaller)
}


// ══════════════════════════════════════════════════════════════════
// F_AuditorReadOnly — a pure auditor (RAuditor ∧ ¬ROfficer) cannot
//   successfully submit or patch (FR-005)
// ══════════════════════════════════════════════════════════════════

fact F_AuditorReadOnly {
  all op: Operation |
    (RAuditor in op.opCaller.userRoles and ROfficer not in op.opCaller.userRoles)
    implies
    (op.opKind in (PostApplications + PatchApplicationStatus) implies op.opOutcome = Failure)
}


// ══════════════════════════════════════════════════════════════════
// F_AuditEndpointAuditorOnly — only RAuditor callers succeed on
//   GetApplicationAudit (FR-023)
// ══════════════════════════════════════════════════════════════════

fact F_AuditEndpointAuditorOnly {
  all op: Operation |
    (op.opKind = GetApplicationAudit and op.opOutcome = Success)
    implies RAuditor in op.opCaller.userRoles
}


// ══════════════════════════════════════════════════════════════════
// F_AuthRequiredEverywhere — a successful operation requires the
//   caller to hold at least one role permitted for that operation
//   (models OAuth 401 gate; FR-001)
// ══════════════════════════════════════════════════════════════════

fact F_AuthRequiredEverywhere {
  all op: Operation |
    op.opOutcome = Success implies
    (some r: op.opCaller.userRoles | r -> op.opKind in PermMatrix.Allowed)
}


// ══════════════════════════════════════════════════════════════════
// F_OwnershipBasedAccess — a successful GET by a non-auditor
//   non-officer caller is only possible when they are the applicant
//   of the target application (FR-003, FR-020/021)
// ══════════════════════════════════════════════════════════════════

fact F_OwnershipBasedAccess {
  all op: Operation |
    (op.opKind = GetApplicationById and op.opOutcome = Success and
     RAuditor not in op.opCaller.userRoles and
     ROfficer not in op.opCaller.userRoles)
    implies (some a: LoanApplication |
               op.opTarget = a and op.opCaller = a.appApplicant)
}


// ══════════════════════════════════════════════════════════════════
// F_OfficerAssignedAccess — a successful GET by an officer (who is
//   not also an auditor) requires them to be the assigned officer
//   for that application (FR-004)
// ══════════════════════════════════════════════════════════════════

fact F_OfficerAssignedAccess {
  all op: Operation |
    (op.opKind = GetApplicationById and op.opOutcome = Success and
     ROfficer in op.opCaller.userRoles and
     RAuditor not in op.opCaller.userRoles)
    implies (some a: LoanApplication |
               op.opTarget = a and
               (a.assignedOfficer = op.opCaller or
                op.opCaller = a.appApplicant))
}


// ══════════════════════════════════════════════════════════════════
// F_OfficerCannotPost — a pure officer (ROfficer ∧ ¬RApplicant) cannot
//   successfully POST a new application (FR-004)
// ══════════════════════════════════════════════════════════════════

fact F_OfficerCannotPost {
  all op: Operation |
    (ROfficer in op.opCaller.userRoles and RApplicant not in op.opCaller.userRoles)
    implies (op.opKind = PostApplications implies op.opOutcome = Failure)
}


// ══════════════════════════════════════════════════════════════════
// F_ApplicantCannotModify — applicants cannot successfully PATCH any
//   application's status (FR-024)
// ══════════════════════════════════════════════════════════════════

fact F_ApplicantCannotModify {
  all op: Operation |
    (RApplicant in op.opCaller.userRoles and ROfficer not in op.opCaller.userRoles)
    implies (op.opKind = PatchApplicationStatus implies op.opOutcome = Failure)
}


// ══════════════════════════════════════════════════════════════════
//
//  PREDICATES AND ASSERTIONS
//  (one pred + assert + check per pattern / per FR)
//
// ══════════════════════════════════════════════════════════════════


// ── PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md §Permission matrix ──

pred LeastPrivilege {
  some op: Operation | op.opOutcome = Success  // universe is non-trivial
  // Every successful operation traces to a permitted (role, operation) cell
  all op: Operation |
    op.opOutcome = Success implies
    (some r: op.opCaller.userRoles | r -> op.opKind in PermMatrix.Allowed)
  // No cell outside the allowed set ever leads to success
  all op: Operation |
    (all r: op.opCaller.userRoles | r -> op.opKind not in PermMatrix.Allowed)
    implies op.opOutcome = Failure
}

assert LeastPrivilege { LeastPrivilege }
check  LeastPrivilege for 6


// ── PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md §Permission matrix ──

pred PermissionCompleteness {
  // Every (Role, OperationKind) pair has a defined verdict: either in Allowed or not
  // i.e., Allowed is a total binary decision; no undefined cells exist (the matrix is complete)
  all r: Role - RSystem, k: OperationKind |
    (r -> k in PermMatrix.Allowed) or (r -> k not in PermMatrix.Allowed)
  // Additionally, auditors are NOT in the Allowed set for write operations
  RAuditor -> PostApplications    not in PermMatrix.Allowed
  RAuditor -> PatchApplicationStatus not in PermMatrix.Allowed
  // Applicants are NOT in the Allowed set for audit read or patch
  RApplicant -> PatchApplicationStatus not in PermMatrix.Allowed
  RApplicant -> GetApplicationAudit    not in PermMatrix.Allowed
}

assert PermissionCompleteness { PermissionCompleteness }
check  PermissionCompleteness for 6


// ── PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-005; contracts/http-api.md §Permission matrix ──
// Auditor's read privileges ⊇ applicant's read privileges ⊇ {} for write ops

pred PrivilegeMonotonicity {
  some op: Operation | op.opOutcome = Success
  // Auditor can do everything applicant can do on read paths
  all k: OperationKind |
    (RApplicant -> k in PermMatrix.Allowed and k not in (PostApplications + PatchApplicationStatus))
    implies (RAuditor -> k in PermMatrix.Allowed)
  // Auditor is a strict superset of applicant on reads: auditor can also read audit log
  RAuditor -> GetApplicationAudit in PermMatrix.Allowed
  RApplicant -> GetApplicationAudit not in PermMatrix.Allowed
}

assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check  PrivilegeMonotonicity for 6


// ── PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md §Authentication ──

pred AuthRequiredEverywhere {
  some op: Operation | op.opOutcome = Success
  // Every successful operation has a caller with at least one permitted role for that op
  all op: Operation |
    op.opOutcome = Success implies
    (some r: op.opCaller.userRoles | r -> op.opKind in PermMatrix.Allowed)
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check  AuthRequiredEverywhere for 6


// ── PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016/FR-017; data-model.md §AuditEntry ──

pred AuditCompleteness {
  some a: LoanApplication | some e: AuditEntry | e.entryApp = a
  // Every application has at least one audit entry
  all a: LoanApplication | (some e: AuditEntry | e.entryApp = a)
  // Every application's current status is witnessed by some audit entry
  all a: LoanApplication | (some e: AuditEntry | e.entryApp = a and e.entryNewStatus = a.appStatus)
  // Every application has exactly one initial audit entry (prev = null)
  all a: LoanApplication | (one e: AuditEntry | e.entryApp = a and no e.entryPrevStatus)
}

assert AuditCompleteness { AuditCompleteness }
check  AuditCompleteness for 6


// ── PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE" ──

pred AppendOnly {
  some a: LoanApplication | #{ e: AuditEntry | e.entryApp = a } > 1
  // No two distinct audit entries on the same application share (prevStatus, newStatus)
  all disj e1, e2: AuditEntry |
    e1.entryApp = e2.entryApp implies
    not (e1.entryPrevStatus = e2.entryPrevStatus and e1.entryNewStatus = e2.entryNewStatus)
  // Exactly one initial entry per application
  all a: LoanApplication | (lone e: AuditEntry | e.entryApp = a and no e.entryPrevStatus)
}

assert AppendOnly { AppendOnly }
check  AppendOnly for 6


// ── PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md §AuditEntry fields ──

pred AttributionCorrectness {
  some e: AuditEntry | e.entryActorRole != RSystem
  // Non-system actors: recorded role must be in the actor's actual role set
  all e: AuditEntry |
    e.entryActorRole != RSystem implies e.entryActorRole in e.entryActor.userRoles
  // PATCH transitions must be attributed to an officer
  all e: AuditEntry |
    some e.entryPrevStatus implies e.entryActorRole = ROfficer
  // Initial submission attributed to applicant or system
  all e: AuditEntry |
    no e.entryPrevStatus implies e.entryActorRole in (RApplicant + RSystem)
}

assert AttributionCorrectness { AttributionCorrectness }
check  AttributionCorrectness for 6


// ── PATTERN: OwnershipExclusivity  ANCHOR: data-model.md §LoanApplication applicant_id ──

pred OwnershipExclusivity {
  some LoanApplication
  // Each application's appApplicant must hold the applicant role
  all a: LoanApplication | RApplicant in a.appApplicant.userRoles
  // Assigned officer must hold the officer role (when set)
  all a: LoanApplication |
    some a.assignedOfficer implies ROfficer in a.assignedOfficer.userRoles
}

assert OwnershipExclusivity { OwnershipExclusivity }
check  OwnershipExclusivity for 6


// ── PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003/FR-020/FR-021 ──

pred OwnershipBasedAccess {
  some op: Operation | op.opKind = GetApplicationById and op.opOutcome = Success
  // Non-officer, non-auditor callers can only GET their own application
  all op: Operation |
    (op.opKind = GetApplicationById and op.opOutcome = Success and
     RAuditor not in op.opCaller.userRoles and
     ROfficer not in op.opCaller.userRoles)
    implies (some a: LoanApplication | op.opTarget = a and op.opCaller = a.appApplicant)
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check  OwnershipBasedAccess for 6


// ── PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020/FR-021; contracts/http-api.md §Byte-equivalent ──
// In the structural model: a caller without legitimate access never achieves Success on GET

pred NoInformationLeakage {
  some op: Operation | op.opKind = GetApplicationById
  // Any successful GET must be via a legitimate access path
  all op: Operation |
    (op.opKind = GetApplicationById and op.opOutcome = Success)
    implies (
      // Path 1: pure applicant viewing own app
      (RAuditor not in op.opCaller.userRoles and ROfficer not in op.opCaller.userRoles and
       some a: LoanApplication | op.opTarget = a and op.opCaller = a.appApplicant)
      or
      // Path 2: auditor (any app)
      RAuditor in op.opCaller.userRoles
      or
      // Path 3: officer viewing assigned application (or own as applicant)
      (ROfficer in op.opCaller.userRoles and
       some a: LoanApplication | op.opTarget = a and
       (a.assignedOfficer = op.opCaller or op.opCaller = a.appApplicant))
    )
}

assert NoInformationLeakage { NoInformationLeakage }
check  NoInformationLeakage for 6


// ── PATTERN: NoSelfMutation  ANCHOR: spec.md FR-013; data-model.md CHECK assigned_officer_id != applicant_id ──

pred NoSelfMutation {
  some op: Operation | op.opKind = PatchApplicationStatus and op.opOutcome = Success
  // A successful PATCH caller is never the application's own applicant
  all op: Operation |
    (op.opKind = PatchApplicationStatus and op.opOutcome = Success)
    implies (some a: LoanApplication | op.opTarget = a and op.opCaller != a.appApplicant)
}

assert NoSelfMutation { NoSelfMutation }
check  NoSelfMutation for 6


// ── PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-007/FR-008/FR-014 ──
// A rejected (Failure) operation leaves no state change — modeled as:
// no successful PATCH on an application in a terminal state

pred ValidationBeforeMutation {
  some LoanApplication
  // Successful PATCH only possible when app is not in a terminal state
  all op: Operation |
    (op.opKind = PatchApplicationStatus and op.opOutcome = Success)
    implies (some a: LoanApplication |
               op.opTarget = a and a.appStatus not in (Approved + Rejected))
}

assert ValidationBeforeMutation { ValidationBeforeMutation }
check  ValidationBeforeMutation for 6


// ──────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC predicates
// ──────────────────────────────────────────────────────────────────


// FEATURE-SPECIFIC  ANCHOR: FR-002 — officer and auditor mutually exclusive

pred FR_002_RoleMultiplicity {
  some u: User | ROfficer in u.userRoles
  some u: User | RAuditor in u.userRoles
  all u: User |
    not (ROfficer in u.userRoles and RAuditor in u.userRoles)
  all u: User | RSystem not in u.userRoles
}

assert FR_002_RoleMultiplicity { FR_002_RoleMultiplicity }
check  FR_002_RoleMultiplicity for 6


// FEATURE-SPECIFIC  ANCHOR: FR-003 — applicants cannot PATCH and cannot read audit

pred FR_003_ApplicantRestrictions {
  some op: Operation | RApplicant in op.opCaller.userRoles
  // Pure applicant: no successful PATCH
  all op: Operation |
    (RApplicant in op.opCaller.userRoles and ROfficer not in op.opCaller.userRoles)
    implies (op.opKind = PatchApplicationStatus implies op.opOutcome = Failure)
  // Pure applicant: no successful read of audit endpoint
  all op: Operation |
    (RApplicant in op.opCaller.userRoles and RAuditor not in op.opCaller.userRoles)
    implies (op.opKind = GetApplicationAudit implies op.opOutcome = Failure)
}

assert FR_003_ApplicantRestrictions { FR_003_ApplicantRestrictions }
check  FR_003_ApplicantRestrictions for 6


// FEATURE-SPECIFIC  ANCHOR: FR-005 — auditor has no write access

pred FR_005_AuditorReadOnly {
  some op: Operation | RAuditor in op.opCaller.userRoles
  all op: Operation |
    (RAuditor in op.opCaller.userRoles and ROfficer not in op.opCaller.userRoles)
    implies
    ((op.opKind = PostApplications       implies op.opOutcome = Failure) and
     (op.opKind = PatchApplicationStatus implies op.opOutcome = Failure))
}

assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check  FR_005_AuditorReadOnly for 6


// FEATURE-SPECIFIC  ANCHOR: FR-008 — at most one in-flight application per applicant

pred FR_008_OneInFlightPerApplicant {
  some a: LoanApplication | a.appStatus in (Pending + UnderReview)
  all disj a1, a2: LoanApplication |
    a1.appApplicant = a2.appApplicant implies
    not (a1.appStatus in (Pending + UnderReview) and
         a2.appStatus in (Pending + UnderReview))
}

assert FR_008_OneInFlightPerApplicant { FR_008_OneInFlightPerApplicant }
check  FR_008_OneInFlightPerApplicant for 6


// FEATURE-SPECIFIC  ANCHOR: FR-009 — only allowed status transitions in audit log

pred FR_009_ValidTransitions {
  some e: AuditEntry | some e.entryPrevStatus
  all e: AuditEntry | {
    (no e.entryPrevStatus) iff (e.entryNewStatus = Pending)
    some e.entryPrevStatus implies {
      (e.entryPrevStatus = Pending     implies e.entryNewStatus = UnderReview) and
      (e.entryPrevStatus = UnderReview implies e.entryNewStatus in (Approved + Rejected))
    }
    e.entryPrevStatus not in (Approved + Rejected)
  }
}

assert FR_009_ValidTransitions { FR_009_ValidTransitions }
check  FR_009_ValidTransitions for 6


// FEATURE-SPECIFIC  ANCHOR: FR-011 — assigned officer ≠ applicant (no self-assignment)

pred FR_011_NoSelfAssignment {
  some a: LoanApplication | some a.assignedOfficer
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.appApplicant
}

assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check  FR_011_NoSelfAssignment for 6


// FEATURE-SPECIFIC  ANCHOR: FR-012 — only assigned officer can successfully PATCH

pred FR_012_OnlyAssignedOfficerCanPatch {
  some op: Operation | op.opKind = PatchApplicationStatus and op.opOutcome = Success
  all op: Operation |
    (op.opKind = PatchApplicationStatus and op.opOutcome = Success)
    implies (some a: LoanApplication |
               op.opTarget = a and a.assignedOfficer = op.opCaller)
}

assert FR_012_OnlyAssignedOfficerCanPatch { FR_012_OnlyAssignedOfficerCanPatch }
check  FR_012_OnlyAssignedOfficerCanPatch for 6


// FEATURE-SPECIFIC  ANCHOR: FR-013 — officer cannot decide their own application

pred FR_013_NoSelfApproval {
  some op: Operation | op.opKind = PatchApplicationStatus and op.opOutcome = Success
  all op: Operation |
    (op.opKind = PatchApplicationStatus and op.opOutcome = Success)
    implies (some a: LoanApplication |
               op.opTarget = a and op.opCaller != a.appApplicant)
}

assert FR_013_NoSelfApproval { FR_013_NoSelfApproval }
check  FR_013_NoSelfApproval for 6


// FEATURE-SPECIFIC  ANCHOR: FR-015 — terminal states (approved/rejected) cannot be patched

pred FR_015_TerminalStatesFinal {
  some a: LoanApplication | a.appStatus in (Approved + Rejected)
  all op: Operation |
    (op.opKind = PatchApplicationStatus and op.opOutcome = Success)
    implies (some a: LoanApplication |
               op.opTarget = a and a.appStatus not in (Approved + Rejected))
  // Equivalently: no audit entry records a transition from a terminal state
  all e: AuditEntry | e.entryPrevStatus not in (Approved + Rejected)
}

assert FR_015_TerminalStatesFinal { FR_015_TerminalStatesFinal }
check  FR_015_TerminalStatesFinal for 6


// FEATURE-SPECIFIC  ANCHOR: FR-016/FR-017 — every observable state has an audit entry

pred FR_016_AuditEntryPerTransition {
  some LoanApplication
  all a: LoanApplication | (some e: AuditEntry | e.entryApp = a)
  all a: LoanApplication | (some e: AuditEntry | e.entryApp = a and e.entryNewStatus = a.appStatus)
  all a: LoanApplication | (one e: AuditEntry | e.entryApp = a and no e.entryPrevStatus)
}

assert FR_016_AuditEntryPerTransition { FR_016_AuditEntryPerTransition }
check  FR_016_AuditEntryPerTransition for 6


// FEATURE-SPECIFIC  ANCHOR: FR-018 — audit log is append-only; no duplicate transitions

pred FR_018_AuditImmutable {
  some a: LoanApplication | #{ e: AuditEntry | e.entryApp = a } > 1
  all disj e1, e2: AuditEntry |
    e1.entryApp = e2.entryApp implies
    not (e1.entryPrevStatus = e2.entryPrevStatus and e1.entryNewStatus = e2.entryNewStatus)
}

assert FR_018_AuditImmutable { FR_018_AuditImmutable }
check  FR_018_AuditImmutable for 6


// FEATURE-SPECIFIC  ANCHOR: FR-023 — GET audit endpoint restricted to auditors only

pred FR_023_AuditEndpointAuditorOnly {
  some op: Operation | op.opKind = GetApplicationAudit
  all op: Operation |
    (op.opKind = GetApplicationAudit and op.opOutcome = Success)
    implies RAuditor in op.opCaller.userRoles
  // Non-auditors always fail on this endpoint
  all op: Operation |
    (RAuditor not in op.opCaller.userRoles)
    implies (op.opKind = GetApplicationAudit implies op.opOutcome = Failure)
}

assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check  FR_023_AuditEndpointAuditorOnly for 6


// FEATURE-SPECIFIC  ANCHOR: FR-024 — applicant cannot modify application post-submission

pred FR_024_ApplicantCannotModifyPostSubmission {
  some op: Operation | RApplicant in op.opCaller.userRoles
  all op: Operation |
    (RApplicant in op.opCaller.userRoles and ROfficer not in op.opCaller.userRoles)
    implies (op.opKind = PatchApplicationStatus implies op.opOutcome = Failure)
}

assert FR_024_ApplicantCannotModifyPostSubmission { FR_024_ApplicantCannotModifyPostSubmission }
check  FR_024_ApplicantCannotModifyPostSubmission for 6


// FEATURE-SPECIFIC  ANCHOR: FR-002/spec.md §Role assignment — no user holds officer+auditor

pred FR_002_OfficerAuditorMutuallyExclusive {
  some u: User | ROfficer in u.userRoles
  some u: User | RAuditor in u.userRoles
  no u: User | ROfficer in u.userRoles and RAuditor in u.userRoles
}

assert FR_002_OfficerAuditorMutuallyExclusive { FR_002_OfficerAuditorMutuallyExclusive }
check  FR_002_OfficerAuditorMutuallyExclusive for 6


// FEATURE-SPECIFIC  ANCHOR: FR-009 — no-op (self-loop) transitions are forbidden

pred FR_009_NoSelfLoopTransitions {
  some e: AuditEntry | some e.entryPrevStatus
  all e: AuditEntry |
    some e.entryPrevStatus implies e.entryPrevStatus != e.entryNewStatus
}

assert FR_009_NoSelfLoopTransitions { FR_009_NoSelfLoopTransitions }
check  FR_009_NoSelfLoopTransitions for 6


// FEATURE-SPECIFIC  ANCHOR: FR-010 — on submission audit entry actor = applicant (or system)

pred FR_010_SubmissionAttributedToApplicantOrSystem {
  some e: AuditEntry | no e.entryPrevStatus
  all e: AuditEntry |
    no e.entryPrevStatus implies
    (e.entryActorRole = RApplicant or e.entryActorRole = RSystem)
}

assert FR_010_SubmissionAttributedToApplicantOrSystem {
  FR_010_SubmissionAttributedToApplicantOrSystem
}
check  FR_010_SubmissionAttributedToApplicantOrSystem for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_SelfApprovalViolation { some op: Operation, a: LoanApplication | op.opKind = PatchApplicationStatus and op.opOutcome = Success and op.opTarget = a and op.opCaller = a.appApplicant }
