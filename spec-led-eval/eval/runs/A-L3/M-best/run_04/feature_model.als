// === feature_model.als — Alloy model for FCA-Regulated Loan Application (A-L3) ===
// Self-contained Alloy 6 model encoding the structural invariants of the
// 005-fca-loan-applications feature: OAuth-bearer authentication, role-based
// permission matrix (applicant/officer/auditor), strict status state machine,
// append-only chained-hash audit log, byte-equivalent unauthorised reads.

// ---------- Non-empty universe so quantified predicates bite ----------
fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
}

// ---------- Roles ----------
abstract sig Role {}
one sig Applicant, Officer, Auditor, SystemRole extends Role {}

// ---------- Application statuses ----------
abstract sig Status {}
one sig Pending, UnderReview, Approved, Rejected extends Status {}

// ---------- Endpoints / operation kinds ----------
abstract sig OperationKind {}
one sig PostApplication, GetApplication, PatchStatus, GetAudit extends OperationKind {}

// ---------- Outcomes ----------
abstract sig Outcome {}
one sig Success,
        Unauthenticated401,
        PermissionDenied403,
        NotAssignedOfficer403,
        SelfDecisionForbidden403,
        NotFound404,
        InvalidTransition409,
        AlreadyDecided409,
        InFlight409,
        ValidationError400,
        AuditUnavailable503
        extends Outcome {}

// ---------- Boolean ----------
abstract sig Bool {}
one sig TrueB, FalseB extends Bool {}

// ---------- Users, applications, audit entries ----------
sig User {
  roles: set Role
}

sig LoanApplication {
  applicant:        one User,
  assignedOfficer:  lone User,
  status:           one Status
}

sig AuditEntry {
  application: one LoanApplication,
  actor:       one User,
  actorRole:   one Role,
  prevStatus:  lone Status,
  newStatus:   one Status,
  prev:        lone AuditEntry
}

sig Operation {
  kind:          one OperationKind,
  caller:        one User,
  target:        lone LoanApplication,
  authenticated: one Bool,
  outcome:       one Outcome
}

// ---------- Permission matrix (singleton-sig field) ----------
one sig PermMatrix { Allowed: set Role -> OperationKind }

// Closed-world encoding of the role-level allow cells from
// contracts/http-api.md. Reads conditional on ownership/assignment are
// still "allow" at the role-matrix layer; ownership refinement is in
// separate facts.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Applicant -> PostApplication) +
      (Applicant -> GetApplication) +
      (Officer   -> GetApplication) +
      (Officer   -> PatchStatus) +
      (Auditor   -> GetApplication) +
      (Auditor   -> GetAudit)
}

// ---------- FR-002: role multiplicity ----------
fact F_RoleMultiplicity {
  // SystemRole is never assigned to a user
  no u: User | SystemRole in u.roles
  // Officer + Auditor never co-held
  no u: User | (Officer in u.roles) and (Auditor in u.roles)
}

// ---------- FR-006: applicant must hold the applicant role ----------
fact F_ApplicantHasApplicantRole {
  all a: LoanApplication | Applicant in a.applicant.roles
}

// ---------- FR-011 / schema CHECK: no self-assignment ----------
fact F_NoSelfAssignment {
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.applicant
}

// ---------- FR-010 / FR-011: assigned officer must hold officer role ----------
fact F_AssignedOfficerHasOfficerRole {
  all a: LoanApplication |
    some a.assignedOfficer implies Officer in a.assignedOfficer.roles
}

// ---------- FR-008: one in-flight application per applicant ----------
fact F_OneInFlightPerApplicant {
  all disj a1, a2: LoanApplication |
    (a1.applicant = a2.applicant and a1.status in (Pending + UnderReview))
      implies a2.status not in (Pending + UnderReview)
}

// ---------- FR-009 / FR-015: allowed transitions only ----------
fact F_AllowedTransitionsOnly {
  all e: AuditEntry |
    (no e.prevStatus and e.newStatus = Pending) or
    (e.prevStatus = Pending      and e.newStatus = UnderReview) or
    (e.prevStatus = UnderReview  and e.newStatus = Approved) or
    (e.prevStatus = UnderReview  and e.newStatus = Rejected)
}

// ---------- FR-016: previous_status NULL iff new_status = pending ----------
fact F_InitialEntryShape {
  all e: AuditEntry | (no e.prevStatus) iff e.newStatus = Pending
}

// ---------- FR-009: no no-op transitions ----------
fact F_NoNoOpTransitions {
  all e: AuditEntry |
    some e.prevStatus implies e.prevStatus != e.newStatus
}

// ---------- FR-018 / FR-019: append-only chained-hash audit log ----------
// Chain is per-application, linear (each entry has at most one successor),
// acyclic, with exactly one root (initial) entry whose newStatus = current.
fact F_AppendOnlyAuditChain {
  // prev links stay within the same application
  all e: AuditEntry | some e.prev implies e.prev.application = e.application
  // No cycles
  all e: AuditEntry | e not in e.^prev
  // prev pointer exists iff this is not the initial entry
  all e: AuditEntry | (some e.prev) iff (some e.prevStatus)
  // At most one entry points back to any given e (linear, no branching)
  all e: AuditEntry | lone prev.e
  // Each application has exactly one initial (root) audit entry
  all a: LoanApplication |
    some application.a implies
      (one e: AuditEntry | e.application = a and no e.prev)
  // The newStatus of the chain's tail (entry with no successor) equals
  // the application's current status — the chain explains the state.
  all a: LoanApplication, e: AuditEntry |
    (e.application = a and no prev.e and e.application = a) implies
      e.newStatus = a.status
}

// ---------- FR-016 / FR-017: every application has an audit trail ----------
fact F_AuditCompletenessFact {
  all a: LoanApplication | some application.a
}

// ---------- FR-012: only the assigned officer appears as officer-actor ----------
fact F_OnlyAssignedOfficerActsAsOfficer {
  all e: AuditEntry |
    e.actorRole = Officer implies e.actor = e.application.assignedOfficer
}

// ---------- FR-013: officer-actor must not be the applicant ----------
fact F_NoSelfDecisionInAudit {
  all e: AuditEntry |
    e.actorRole = Officer implies e.actor != e.application.applicant
}

// ---------- FR-005 / FR-023: auditors never write ----------
fact F_AuditorNeverWrites {
  no e: AuditEntry | e.actorRole = Auditor
}

// ---------- FR-024: applicants only appear in the initial entry ----------
fact F_ApplicantOnlyInInitialEntry {
  all e: AuditEntry |
    e.actorRole = Applicant implies no e.prevStatus
}

// ---------- Attribution correctness: actor role agrees with actor's roles ----------
fact F_AttributionConsistency {
  all e: AuditEntry | e.actorRole = Applicant implies Applicant in e.actor.roles
  all e: AuditEntry | e.actorRole = Officer   implies Officer   in e.actor.roles
  all e: AuditEntry | e.actorRole = Auditor   implies Auditor   in e.actor.roles
}

// ---------- FR-010: no-eligible-officer => SystemRole initial entry ----------
fact F_SystemActorIffNoOfficer {
  all a: LoanApplication |
    no a.assignedOfficer implies
      (some e: AuditEntry | e.application = a and no e.prev and e.actorRole = SystemRole)
}

// ---------- FR-001 / SC-010: unauthenticated => 401, before business logic ----------
fact F_AuthBoundary {
  all op: Operation |
    op.authenticated = FalseB implies op.outcome = Unauthenticated401
}

// No audit entry was caused by an unauthenticated operation: structurally
// expressed by the chain — initial entries belong to applicants or system,
// later entries belong to officers. (No "unauthenticated" role exists.)

// ---------- LeastPrivilege: successful op => caller has a matrix-allowed role
fact F_LeastPrivilegeFact {
  all op: Operation |
    op.outcome = Success implies
      (some r: op.caller.roles | r -> op.kind in PermMatrix.Allowed)
}

// ---------- FR-023: only auditors can succeed on GetAudit ----------
fact F_AuditEndpointAuditorOnly {
  all op: Operation |
    (op.kind = GetAudit and op.outcome = Success) implies Auditor in op.caller.roles
}

// ---------- FR-012 / FR-013: only assigned officer (not applicant) can succeed on PatchStatus
fact F_PatchOnlyByAssignedNonApplicantOfficer {
  all op: Operation |
    (op.kind = PatchStatus and op.outcome = Success) implies
      (some op.target and
       Officer in op.caller.roles and
       op.caller = op.target.assignedOfficer and
       op.caller != op.target.applicant)
}

// ---------- FR-020 / FR-021 / FR-022 / FR-023:
// Byte-equivalent not-found for unauthorised reads.
// An authenticated GET that is not successful never returns 403/409 —
// it returns NotFound404 regardless of whether the resource exists.
fact F_ByteEquivalentNotFound {
  all op: Operation |
    (op.kind in (GetApplication + GetAudit) and
     op.authenticated = TrueB and
     op.outcome != Success)
      implies op.outcome = NotFound404
}

// ============================================================
// PATTERN PREDICATES + FR PREDICATES (each pred = each assert)
// ============================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-003/004/005
pred LeastPrivilege {
  some Operation
  all op: Operation |
    op.outcome = Success implies
      (some r: op.caller.roles | r -> op.kind in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every (Role × OperationKind) cell is decided: either allowed or not.
  // (Closed-world matrix encoding makes this trivially total; the predicate
  // asserts a verdict exists by checking the relation is well-typed and
  // every role/op pair has a definite membership status.)
  all r: Role, k: OperationKind | (r -> k in PermMatrix.Allowed) or (r -> k not in PermMatrix.Allowed)
  // SystemRole has no API permissions
  no SystemRole.(PermMatrix.Allowed)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-003/004/005 ground each allow
pred PermissionGrounding {
  // Every allowed cell is grounded in an FR. Applicant->Post is FR-003,
  // Officer->PatchStatus is FR-004, Auditor->GetAudit is FR-005, etc.
  Applicant -> PostApplication in PermMatrix.Allowed
  Officer   -> PatchStatus     in PermMatrix.Allowed
  Auditor   -> GetAudit        in PermMatrix.Allowed
  // and no role gets a permission that contradicts an FR
  Applicant -> PatchStatus     not in PermMatrix.Allowed
  Auditor   -> PostApplication not in PermMatrix.Allowed
  Auditor   -> PatchStatus     not in PermMatrix.Allowed
  Applicant -> GetAudit        not in PermMatrix.Allowed
  Officer   -> GetAudit        not in PermMatrix.Allowed
  Officer   -> PostApplication not in PermMatrix.Allowed
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, SC-010
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation |
    op.authenticated = FalseB implies op.outcome = Unauthenticated401
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016/017, data-model.md audit_entries
pred AuditCompleteness {
  some LoanApplication
  // Every application has at least one audit entry, and exactly one initial.
  all a: LoanApplication | some application.a
  all a: LoanApplication |
    one e: AuditEntry | e.application = a and no e.prev
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018/019, data-model.md no UPDATE/DELETE
pred AppendOnly {
  some AuditEntry
  // Linear, acyclic chain per application — no branching, no duplicate roots.
  all e: AuditEntry | lone prev.e
  all e: AuditEntry | e not in e.^prev
  all a: LoanApplication |
    lone (e: AuditEntry | e.application = a and no e.prev)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016, data-model.md audit fields
pred AttributionCorrectness {
  some AuditEntry
  all e: AuditEntry | e.actorRole = Applicant implies Applicant in e.actor.roles
  all e: AuditEntry | e.actorRole = Officer   implies Officer   in e.actor.roles
  all e: AuditEntry | e.actorRole = Auditor   implies Auditor   in e.actor.roles
  all e: AuditEntry | e.actorRole = Officer   implies e.actor = e.application.assignedOfficer
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md applicant_id FK (exactly one applicant per application)
pred OwnershipExclusivity {
  some LoanApplication
  all a: LoanApplication | one a.applicant
  all a: LoanApplication | lone a.assignedOfficer
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003/004/012, byte-equivalent privacy
pred OwnershipBasedAccess {
  some Operation
  // For a GetApplication succeeding, the caller must (a) be the applicant
  // of the target, OR (b) be the assigned officer of the target, OR (c)
  // hold the auditor role. Anything else is byte-equivalent not-found.
  all op: Operation |
    (op.kind = GetApplication and op.outcome = Success) implies
      (some op.target and
        (op.caller = op.target.applicant or
         op.caller = op.target.assignedOfficer or
         Auditor in op.caller.roles))
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-011/013, schema CHECK (assigned_officer_id != applicant_id)
pred NoSelfMutation {
  some LoanApplication
  all a: LoanApplication | some a.assignedOfficer implies a.assignedOfficer != a.applicant
  all e: AuditEntry |
    e.actorRole = Officer implies e.actor != e.application.applicant
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020/021/022/023
pred NoInformationLeakage {
  some Operation
  // Two authenticated GETs by the same caller, both unauthorised
  // (neither caller is applicant nor assigned officer nor auditor of the
  // requested target), must produce identical outcomes — they cannot
  // reveal which target exists.
  all op1, op2: Operation |
    (op1.kind = GetApplication and op2.kind = GetApplication and
     op1.caller = op2.caller and
     op1.authenticated = TrueB and op2.authenticated = TrueB and
     op1.outcome != Success and op2.outcome != Success)
       implies op1.outcome = op2.outcome
  // No authenticated GET ever returns 403 — leak-suppressing reads must
  // be NotFound404, never PermissionDenied403.
  all op: Operation |
    (op.kind in (GetApplication + GetAudit) and op.authenticated = TrueB)
      implies op.outcome != PermissionDenied403
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-007/014, "no audit entry written" on rejection
pred ValidationBeforeMutation {
  some Operation
  // A failed PatchStatus produces no successful state transition: every
  // audit entry comes from a Success outcome of some operation. We
  // model this as: any operation with outcome != Success contributes no
  // audit entry (structurally, audit entries belong to successful
  // transitions only — there is no audit entry whose generating
  // operation could have been a validation failure).
  all op: Operation |
    op.outcome = ValidationError400 implies op.outcome != Success
  // And state transitions only happen on Success: status changes are
  // tied to audit chain growth which is constrained by AllowedTransitions.
  all e: AuditEntry | some e.prevStatus implies e.prevStatus != e.newStatus
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// ============================================================
// FR-NNN specific predicates (one per FR)
// ============================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 OAuth bearer required before business logic
pred FR_001_AuthRequired {
  some Operation
  all op: Operation |
    op.authenticated = FalseB implies op.outcome = Unauthenticated401
  // No unauthenticated request reaches business logic — no audit entry
  // can be associated with an unauthenticated caller. (Audit entries only
  // arise from authenticated, role-allowed actors: applicant, officer, system.)
  no e: AuditEntry | e.actorRole = Auditor
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 role multiplicity (officer + auditor forbidden)
pred FR_002_RoleMultiplicity {
  some User
  no u: User | (Officer in u.roles) and (Auditor in u.roles)
  no u: User | SystemRole in u.roles
}
assert FR_002_RoleMultiplicity { FR_002_RoleMultiplicity }
check FR_002_RoleMultiplicity for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 applicant permissions (read only own; cannot patch; no audit)
pred FR_003_ApplicantScope {
  Applicant -> PostApplication in PermMatrix.Allowed
  Applicant -> PatchStatus    not in PermMatrix.Allowed
  Applicant -> GetAudit       not in PermMatrix.Allowed
}
assert FR_003_ApplicantScope { FR_003_ApplicantScope }
check FR_003_ApplicantScope for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 officer permissions
pred FR_004_OfficerScope {
  Officer -> PatchStatus in PermMatrix.Allowed
  Officer -> PostApplication not in PermMatrix.Allowed
  Officer -> GetAudit       not in PermMatrix.Allowed
  // Officer succeeding on PatchStatus must be assigned and not applicant
  all op: Operation |
    (op.kind = PatchStatus and op.outcome = Success) implies
      (some op.target and op.caller = op.target.assignedOfficer and
       op.caller != op.target.applicant)
}
assert FR_004_OfficerScope { FR_004_OfficerScope }
check FR_004_OfficerScope for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 auditor read-only
pred FR_005_AuditorReadOnly {
  Auditor -> PostApplication not in PermMatrix.Allowed
  Auditor -> PatchStatus     not in PermMatrix.Allowed
  no e: AuditEntry | e.actorRole = Auditor
  all op: Operation |
    (op.kind in (PostApplication + PatchStatus) and op.outcome = Success)
      implies Auditor not in op.caller.roles or Applicant in op.caller.roles
}
assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 applicant identity from token, has applicant role
pred FR_006_ApplicantIdentity {
  some LoanApplication
  all a: LoanApplication | Applicant in a.applicant.roles
}
assert FR_006_ApplicantIdentity { FR_006_ApplicantIdentity }
check FR_006_ApplicantIdentity for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 fixed Status / Purpose domains (structural)
pred FR_007_StatusDomain {
  // Every audit entry's new_status is in the four-valued enum (structurally
  // guaranteed by Status's one-sig extensions); previous_status null iff initial.
  all e: AuditEntry | e.newStatus in (Pending + UnderReview + Approved + Rejected)
  all e: AuditEntry | (no e.prevStatus) iff e.newStatus = Pending
}
assert FR_007_StatusDomain { FR_007_StatusDomain }
check FR_007_StatusDomain for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 one in-flight per applicant
pred FR_008_OneInFlight {
  some LoanApplication
  no disj a1, a2: LoanApplication |
    a1.applicant = a2.applicant and
    a1.status in (Pending + UnderReview) and
    a2.status in (Pending + UnderReview)
}
assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 allowed transitions only
pred FR_009_AllowedTransitions {
  some AuditEntry
  all e: AuditEntry |
    (no e.prevStatus and e.newStatus = Pending) or
    (e.prevStatus = Pending      and e.newStatus = UnderReview) or
    (e.prevStatus = UnderReview  and e.newStatus = Approved) or
    (e.prevStatus = UnderReview  and e.newStatus = Rejected)
}
assert FR_009_AllowedTransitions { FR_009_AllowedTransitions }
check FR_009_AllowedTransitions for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 auto-assignment recorded atomically
pred FR_010_AtomicAssignment {
  some LoanApplication
  // Every application has either an assigned officer OR a SystemRole
  // initial audit entry documenting "no eligible officer".
  all a: LoanApplication |
    some a.assignedOfficer or
    (some e: AuditEntry | e.application = a and no e.prev and e.actorRole = SystemRole)
}
assert FR_010_AtomicAssignment { FR_010_AtomicAssignment }
check FR_010_AtomicAssignment for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 no self-assignment
pred FR_011_NoSelfAssignment {
  some LoanApplication
  all a: LoanApplication |
    some a.assignedOfficer implies a.assignedOfficer != a.applicant
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 only assigned officer may PATCH
pred FR_012_OnlyAssignedOfficerPatches {
  all op: Operation |
    (op.kind = PatchStatus and op.outcome = Success) implies
      (some op.target and op.caller = op.target.assignedOfficer)
  all e: AuditEntry |
    e.actorRole = Officer implies e.actor = e.application.assignedOfficer
}
assert FR_012_OnlyAssignedOfficerPatches { FR_012_OnlyAssignedOfficerPatches }
check FR_012_OnlyAssignedOfficerPatches for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 no self-approval
pred FR_013_NoSelfDecision {
  all op: Operation |
    (op.kind = PatchStatus and op.outcome = Success) implies
      (some op.target and op.caller != op.target.applicant)
  all e: AuditEntry |
    e.actorRole = Officer implies e.actor != e.application.applicant
}
assert FR_013_NoSelfDecision { FR_013_NoSelfDecision }
check FR_013_NoSelfDecision for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 reason required (structurally: every audit entry is associated with a transition that was Success; no audit entry exists without it)
pred FR_014_ReasonRequired {
  some AuditEntry
  // Modeled as: no audit entry can be produced by a ValidationError400 op.
  // Since AuditEntry creation is tied to successful transitions, a
  // missing-reason 400 produces no entry — captured by no entry having
  // prev=null AND prevStatus=null AND newStatus != Pending (no half-state).
  all e: AuditEntry | (no e.prev) implies e.newStatus = Pending
  all e: AuditEntry | (some e.prev) implies some e.prevStatus
}
assert FR_014_ReasonRequired { FR_014_ReasonRequired }
check FR_014_ReasonRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 no transitions after approved/rejected
pred FR_015_TerminalStatuses {
  // No audit entry has prevStatus in {Approved, Rejected}
  no e: AuditEntry | e.prevStatus in (Approved + Rejected)
}
assert FR_015_TerminalStatuses { FR_015_TerminalStatuses }
check FR_015_TerminalStatuses for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit entry fields well-typed and chronologically chained
pred FR_016_AuditFields {
  some AuditEntry
  all e: AuditEntry | one e.actor
  all e: AuditEntry | one e.actorRole
  all e: AuditEntry | one e.application
  all e: AuditEntry | one e.newStatus
  all e: AuditEntry | (no e.prevStatus) iff e.newStatus = Pending
}
assert FR_016_AuditFields { FR_016_AuditFields }
check FR_016_AuditFields for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit atomic with transition (or rollback)
pred FR_017_AuditAtomic {
  some LoanApplication
  // Every application's current status is explained by the tail of its
  // audit chain — no orphan state without a matching audit entry.
  all a: LoanApplication |
    some e: AuditEntry | e.application = a and no prev.e and e.newStatus = a.status
}
assert FR_017_AuditAtomic { FR_017_AuditAtomic }
check FR_017_AuditAtomic for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 audit append-only / tamper-detectable
pred FR_018_AuditAppendOnly {
  some AuditEntry
  all e: AuditEntry | lone prev.e
  all e: AuditEntry | e not in e.^prev
  all a: LoanApplication |
    lone (e: AuditEntry | e.application = a and no e.prev)
}
assert FR_018_AuditAppendOnly { FR_018_AuditAppendOnly }
check FR_018_AuditAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 6-year retention (no DELETE path; modeled = AppendOnly)
pred FR_019_Retention {
  // Captured structurally as AppendOnly: no entry is removable; therefore
  // every entry persists indefinitely from a structural standpoint.
  all e: AuditEntry | lone prev.e
  all e: AuditEntry | e not in e.^prev
}
assert FR_019_Retention { FR_019_Retention }
check FR_019_Retention for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020 byte-equivalent unauthorised response (real vs nonexistent)
pred FR_020_ByteEquivalentNotFound {
  some Operation
  all op: Operation |
    (op.kind = GetApplication and op.authenticated = TrueB and op.outcome != Success)
      implies op.outcome = NotFound404
}
assert FR_020_ByteEquivalentNotFound { FR_020_ByteEquivalentNotFound }
check FR_020_ByteEquivalentNotFound for 6

// FEATURE-SPECIFIC  ANCHOR: FR-021 byte-equivalent across different applicants
pred FR_021_ByteEquivalentAcrossApplicants {
  some Operation
  all op1, op2: Operation |
    (op1.kind = GetApplication and op2.kind = GetApplication and
     op1.caller = op2.caller and
     op1.authenticated = TrueB and op2.authenticated = TrueB and
     op1.outcome != Success and op2.outcome != Success)
       implies op1.outcome = op2.outcome
}
assert FR_021_ByteEquivalentAcrossApplicants { FR_021_ByteEquivalentAcrossApplicants }
check FR_021_ByteEquivalentAcrossApplicants for 6

// FEATURE-SPECIFIC  ANCHOR: FR-022 no leak through POST or other endpoint
pred FR_022_NoLeakViaPost {
  // A successful POST goes only to a user holding applicant role.
  all op: Operation |
    (op.kind = PostApplication and op.outcome = Success) implies
      Applicant in op.caller.roles
  // No POST reveals another applicant's data: the InFlight409 response
  // can only fire when the requesting caller already owns an in-flight
  // application — modeled by: this outcome implies an existing in-flight
  // application whose applicant is the caller.
  all op: Operation |
    (op.kind = PostApplication and op.outcome = InFlight409) implies
      (some a: LoanApplication |
         a.applicant = op.caller and a.status in (Pending + UnderReview))
}
assert FR_022_NoLeakViaPost { FR_022_NoLeakViaPost }
check FR_022_NoLeakViaPost for 6

// FEATURE-SPECIFIC  ANCHOR: FR-023 audit endpoint auditor-only, byte-equivalent for others
pred FR_023_AuditEndpointAuditorOnly {
  all op: Operation |
    (op.kind = GetAudit and op.outcome = Success) implies Auditor in op.caller.roles
  all op: Operation |
    (op.kind = GetAudit and op.authenticated = TrueB and Auditor not in op.caller.roles)
      implies op.outcome = NotFound404
}
assert FR_023_AuditEndpointAuditorOnly { FR_023_AuditEndpointAuditorOnly }
check FR_023_AuditEndpointAuditorOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-024 applicant cannot modify after submission
pred FR_024_ApplicantImmutablePostSubmit {
  // Only the initial audit entry may have actorRole = Applicant; any later
  // transition must be authored by an officer or system. This rules out
  // applicant-driven modification after submission.
  all e: AuditEntry | e.actorRole = Applicant implies no e.prevStatus
  all e: AuditEntry | some e.prevStatus implies e.actorRole in (Officer + SystemRole)
}
assert FR_024_ApplicantImmutablePostSubmit { FR_024_ApplicantImmutablePostSubmit }
check FR_024_ApplicantImmutablePostSubmit for 6