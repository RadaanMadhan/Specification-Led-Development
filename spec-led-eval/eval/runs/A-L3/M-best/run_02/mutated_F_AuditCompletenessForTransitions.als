// === feature_model.als — Alloy model for FCA-Regulated Loan Application (A-L3 / 005) ===

// ---------- Static enumerations ----------

abstract sig Role {}
one sig ApplicantRole, OfficerRole, AuditorRole, SystemRole extends Role {}

abstract sig OperationKind {}
one sig PostApplications, GetApplicationById, PatchStatus, GetAudit extends OperationKind {}

abstract sig Status {}
one sig Pending, UnderReview, Approved, Rejected extends Status {}

abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

abstract sig Outcome {}
one sig Success, Unauthenticated, Forbidden, NotFound, ValidationError, Conflict extends Outcome {}

// Permission matrix (Role x OperationKind) as a singleton field
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Dynamic sigs ----------

sig User {
  roles: some Role
}

sig LoanApplication {
  applicant: one User,
  assignedOfficer: lone User,
  status: one Status
}

sig AuditEntry {
  application: one LoanApplication,
  actor: one User,
  actorRole: one Role,
  prevStatus: lone Status,
  newStatus: one Status
}

sig Operation {
  kind: one OperationKind,
  caller: lone User,
  authenticated: one Bool,
  target: one LoanApplication,
  outcome: one Outcome,
  audit: lone AuditEntry
}

// ---------- F_NonEmptyUniverse (mandatory, not a mutation target) ----------

fact F_NonEmptyUniverse {
  some User
  some LoanApplication
  some AuditEntry
  some Operation
}

// ---------- Permission matrix from contracts/http-api.md ----------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (ApplicantRole -> PostApplications) +
    (ApplicantRole -> GetApplicationById) +
    (OfficerRole -> GetApplicationById) +
    (OfficerRole -> PatchStatus) +
    (AuditorRole -> GetApplicationById) +
    (AuditorRole -> GetAudit)
}

// ---------- Role multiplicity & user-role hygiene (FR-002) ----------

fact F_RoleExclusivity {
  all u: User | not (OfficerRole in u.roles and AuditorRole in u.roles)
  all u: User | SystemRole not in u.roles
}

// ---------- Application ownership & assignment invariants ----------

fact F_ApplicantHasApplicantRole {
  all app: LoanApplication | ApplicantRole in app.applicant.roles
}

fact F_AssignedOfficerHasOfficerRole {
  all app: LoanApplication |
    some app.assignedOfficer implies OfficerRole in app.assignedOfficer.roles
}

fact F_NoSelfAssignment {
  // FR-011 + FR-013 defence-in-depth: assigned officer is never the applicant
  all app: LoanApplication |
    some app.assignedOfficer implies app.assignedOfficer != app.applicant
}

fact F_OneInFlightPerApplicant {
  // FR-008
  all disj app1, app2: LoanApplication |
    app1.applicant = app2.applicant implies
      not (app1.status in (Pending + UnderReview) and
           app2.status in (Pending + UnderReview))
}

// ---------- Audit entry structural invariants ----------

fact F_StatusTransitionsValid {
  // FR-009: only allowed transitions appear in audit entries
  all ae: AuditEntry |
    (no ae.prevStatus and ae.newStatus = Pending) or
    (ae.prevStatus = Pending and ae.newStatus = UnderReview) or
    (ae.prevStatus = UnderReview and ae.newStatus = Approved) or
    (ae.prevStatus = UnderReview and ae.newStatus = Rejected)
}

fact F_AuditInitialIffPending {
  all ae: AuditEntry |
    (no ae.prevStatus) iff (ae.newStatus = Pending)
}

fact F_AuditAttribution {
  // FR-016: actor_role matches the actor's role (except for "system")
  all ae: AuditEntry |
    (ae.actorRole != SystemRole) implies ae.actorRole in ae.actor.roles
}

fact F_AppendOnlyAuditEntries {
  // FR-018: at most one audit entry per (application, prevStatus, newStatus)
  all disj ae1, ae2: AuditEntry |
    not (ae1.application = ae2.application and
         ae1.prevStatus = ae2.prevStatus and
         ae1.newStatus = ae2.newStatus)
}

// ---------- Operation/authentication invariants ----------

fact F_AuthenticatedIffCaller {
  all op: Operation | op.authenticated = BTrue iff some op.caller
}

fact F_AuthRequiredBeforeBusinessLogic {
  // FR-001
  all op: Operation |
    (op.authenticated = BFalse) implies
      (op.outcome = Unauthenticated and no op.audit)
  all op: Operation |
    (op.outcome = Unauthenticated) implies (op.authenticated = BFalse)
}

fact F_LeastPrivilegeEnforced {
  // FR-003..FR-005: a successful op requires a role allowed for that op kind
  all op: Operation |
    op.outcome = Success implies
      (some r: op.caller.roles | r -> op.kind in PermMatrix.Allowed)
}

fact F_OnlyAssignedOfficerPatches {
  // FR-012: only the assigned officer can successfully PATCH
  all op: Operation |
    (op.outcome = Success and op.kind = PatchStatus) implies
      op.caller = op.target.assignedOfficer
}

fact F_TerminalNoFurtherTransition {
  // FR-015: no transition out of approved/rejected
  all ae: AuditEntry |
    ae.prevStatus not in (Approved + Rejected)
}

fact F_ApplicantCannotPatch {
  // FR-024: applicants cannot mutate applications post-submission
  all op: Operation |
    (op.outcome = Success and op.kind = PatchStatus) implies
      OfficerRole in op.caller.roles
}

// ---------- Audit completeness & coupling to operations ----------

fact F_AuditCompletenessForTransitions { /* MUTATED — body cleared by validator */ }

fact F_AuditOperationCoupling {
  // The audit entry produced by an operation refers to that operation's caller & target
  all op: Operation |
    some op.audit implies
      (op.audit.actor = op.caller and op.audit.application = op.target)
}

// ---------- Information-disclosure invariants ----------

fact F_NoInformationLeakageOnRead {
  // FR-020 / FR-021 / FR-023: authenticated read denials always look like "not found"
  all op: Operation |
    (op.authenticated = BTrue and
     op.kind in (GetApplicationById + GetAudit) and
     op.outcome != Success) implies op.outcome = NotFound
}

fact F_OwnershipBasedReadAccess {
  // Successful GET /applications/{id}: caller is applicant, assigned officer, or auditor
  all op: Operation |
    (op.kind = GetApplicationById and op.outcome = Success) implies
      (op.caller = op.target.applicant or
       op.caller = op.target.assignedOfficer or
       AuditorRole in op.caller.roles)
  // Successful GET audit: caller must have auditor role (FR-023)
  all op: Operation |
    (op.kind = GetAudit and op.outcome = Success) implies
      AuditorRole in op.caller.roles
}

// ============================================================
// Pattern predicates and assertions
// ============================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-003..FR-005
pred LeastPrivilege {
  all op: Operation |
    op.outcome = Success implies
      (some r: op.caller.roles | r -> op.kind in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // The expected matrix cells are present
  ApplicantRole -> PostApplications in PermMatrix.Allowed
  ApplicantRole -> GetApplicationById in PermMatrix.Allowed
  OfficerRole -> GetApplicationById in PermMatrix.Allowed
  OfficerRole -> PatchStatus in PermMatrix.Allowed
  AuditorRole -> GetApplicationById in PermMatrix.Allowed
  AuditorRole -> GetAudit in PermMatrix.Allowed
  // Critical denials
  AuditorRole -> PatchStatus not in PermMatrix.Allowed
  AuditorRole -> PostApplications not in PermMatrix.Allowed
  ApplicantRole -> PatchStatus not in PermMatrix.Allowed
  ApplicantRole -> GetAudit not in PermMatrix.Allowed
  OfficerRole -> PostApplications not in PermMatrix.Allowed
  OfficerRole -> GetAudit not in PermMatrix.Allowed
  SystemRole -> PostApplications not in PermMatrix.Allowed
  SystemRole -> GetApplicationById not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication
pred AuthRequiredEverywhere {
  all op: Operation |
    op.authenticated = BFalse implies
      (op.outcome = Unauthenticated and no op.audit)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-016, FR-017; data-model.md audit_entries
pred AuditCompleteness {
  // Every successful state-changing op has exactly one audit entry
  all op: Operation |
    (op.outcome = Success and op.kind in (PostApplications + PatchStatus)) implies
      (one op.audit)
  // No audit entry exists detached from an operation
  all ae: AuditEntry | some op: Operation | op.audit = ae
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  // Two distinct audit entries can never record the same transition on the same application
  all disj ae1, ae2: AuditEntry |
    not (ae1.application = ae2.application and
         ae1.prevStatus = ae2.prevStatus and
         ae1.newStatus = ae2.newStatus)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-016; data-model.md audit_entries.actor_role
pred AttributionCorrectness {
  // Recorded actor_role matches the actor's actual roles (except for the system sentinel)
  all ae: AuditEntry |
    ae.actorRole != SystemRole implies ae.actorRole in ae.actor.roles
  // The audit entry's actor matches the operation's caller
  all op: Operation |
    some op.audit implies op.audit.actor = op.caller
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md loan_applications.applicant_id
pred OwnershipExclusivity {
  // No two distinct applications share the same identifier semantics: each LoanApplication
  // has exactly one applicant, and that applicant holds the applicant role.
  all app: LoanApplication | one app.applicant and ApplicantRole in app.applicant.roles
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003, FR-004, FR-020; contracts/http-api.md GET /applications/{id}
pred OwnershipBasedAccess {
  all op: Operation |
    (op.kind = GetApplicationById and op.outcome = Success) implies
      (op.caller = op.target.applicant or
       op.caller = op.target.assignedOfficer or
       AuditorRole in op.caller.roles)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-020, FR-021, FR-022, FR-023
pred NoInformationLeakage {
  all op: Operation |
    (op.authenticated = BTrue and
     op.kind in (GetApplicationById + GetAudit) and
     op.outcome != Success) implies op.outcome = NotFound
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-011, FR-013; data-model.md CHECK(assigned_officer_id != applicant_id)
pred NoSelfMutation {
  // No application is self-assigned, and consequently no PATCH success is a self-decision
  all app: LoanApplication |
    some app.assignedOfficer implies app.assignedOfficer != app.applicant
  all op: Operation |
    (op.outcome = Success and op.kind = PatchStatus) implies
      op.caller != op.target.applicant
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-007, FR-014; data-model.md atomicity contract
pred ValidationBeforeMutation {
  // Validation failure produces no audit entry and no state-change side-effect
  all op: Operation |
    (op.outcome = ValidationError) implies no op.audit
  all op: Operation |
    (op.outcome != Success) implies no op.audit
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// ============================================================
// Feature-specific FR-NNN predicates
// ============================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 OAuth required, 401 before business logic
pred FR_001_AuthRequired {
  all op: Operation |
    op.authenticated = BFalse implies
      (op.outcome = Unauthenticated and no op.audit)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 role multiplicity (officer XOR auditor)
pred FR_002_RoleExclusivity {
  all u: User | not (OfficerRole in u.roles and AuditorRole in u.roles)
  all u: User | SystemRole not in u.roles
}
assert FR_002_RoleExclusivity { FR_002_RoleExclusivity }
check FR_002_RoleExclusivity for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 applicants can submit/read own, nothing else
pred FR_003_ApplicantScope {
  all op: Operation |
    (op.outcome = Success and op.caller.roles = ApplicantRole) implies
      op.kind in (PostApplications + GetApplicationById)
}
assert FR_003_ApplicantScope { FR_003_ApplicantScope }
check FR_003_ApplicantScope for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 officer can only PATCH applications assigned to them
pred FR_004_OfficerAssignedOnly {
  all op: Operation |
    (op.outcome = Success and op.kind = PatchStatus) implies
      op.caller = op.target.assignedOfficer
}
assert FR_004_OfficerAssignedOnly { FR_004_OfficerAssignedOnly }
check FR_004_OfficerAssignedOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 auditor read-only (no writes)
pred FR_005_AuditorReadOnly {
  all op: Operation |
    (op.outcome = Success and op.caller.roles = AuditorRole) implies
      op.kind in (GetApplicationById + GetAudit)
}
assert FR_005_AuditorReadOnly { FR_005_AuditorReadOnly }
check FR_005_AuditorReadOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 at most one in-flight application per applicant
pred FR_008_OneInFlight {
  all disj app1, app2: LoanApplication |
    app1.applicant = app2.applicant implies
      not (app1.status in (Pending + UnderReview) and
           app2.status in (Pending + UnderReview))
}
assert FR_008_OneInFlight { FR_008_OneInFlight }
check FR_008_OneInFlight for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 status transitions
pred FR_009_ValidTransitions {
  all ae: AuditEntry |
    (no ae.prevStatus and ae.newStatus = Pending) or
    (ae.prevStatus = Pending and ae.newStatus = UnderReview) or
    (ae.prevStatus = UnderReview and ae.newStatus = Approved) or
    (ae.prevStatus = UnderReview and ae.newStatus = Rejected)
}
assert FR_009_ValidTransitions { FR_009_ValidTransitions }
check FR_009_ValidTransitions for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 assigned officer is an officer-role user
pred FR_010_AssignedIsOfficer {
  all app: LoanApplication |
    some app.assignedOfficer implies OfficerRole in app.assignedOfficer.roles
}
assert FR_010_AssignedIsOfficer { FR_010_AssignedIsOfficer }
check FR_010_AssignedIsOfficer for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 no self-assignment
pred FR_011_NoSelfAssignment {
  all app: LoanApplication |
    some app.assignedOfficer implies app.assignedOfficer != app.applicant
}
assert FR_011_NoSelfAssignment { FR_011_NoSelfAssignment }
check FR_011_NoSelfAssignment for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 only assigned officer can PATCH
pred FR_012_OnlyAssignedOfficer {
  all op: Operation |
    (op.outcome = Success and op.kind = PatchStatus) implies
      op.caller = op.target.assignedOfficer
}
assert FR_012_OnlyAssignedOfficer { FR_012_OnlyAssignedOfficer }
check FR_012_OnlyAssignedOfficer for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 no self-decision (officer cannot decide own application)
pred FR_013_NoSelfDecision {
  all op: Operation |
    (op.outcome = Success and op.kind = PatchStatus) implies
      op.caller != op.target.applicant
}
assert FR_013_NoSelfDecision { FR_013_NoSelfDecision }
check FR_013_NoSelfDecision for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 no PATCH out of terminal states
pred FR_015_TerminalNoFurther {
  all ae: AuditEntry | ae.prevStatus not in (Approved + Rejected)
}
assert FR_015_TerminalNoFurther { FR_015_TerminalNoFurther }
check FR_015_TerminalNoFurther for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit entry fields and attribution
pred FR_016_AuditFields {
  all ae: AuditEntry |
    (no ae.prevStatus) iff (ae.newStatus = Pending)
  all ae: AuditEntry |
    ae.actorRole != SystemRole implies ae.actorRole in ae.actor.roles
}
assert FR_016_AuditFields { FR_016_AuditFields }
check FR_016_AuditFields for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 audit append-only / no duplicates
pred FR_018_AppendOnly {
  all disj ae1, ae2: AuditEntry |
    not (ae1.application = ae2.application and
         ae1.prevStatus = ae2.prevStatus and
         ae1.newStatus = ae2.newStatus)
  // Every audit entry is the unique audit produced by some operation
  all ae: AuditEntry | one op: Operation | op.audit = ae
}
assert FR_018_AppendOnly { FR_018_AppendOnly }
check FR_018_AppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020/021/022 byte-equivalent unauthorised read
pred FR_020_ByteEquivalent {
  all op: Operation |
    (op.authenticated = BTrue and
     op.kind = GetApplicationById and
     op.outcome != Success) implies op.outcome = NotFound
}
assert FR_020_ByteEquivalent { FR_020_ByteEquivalent }
check FR_020_ByteEquivalent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-023 audit endpoint is auditor-only
pred FR_023_AuditAuditorOnly {
  all op: Operation |
    (op.kind = GetAudit and op.outcome = Success) implies
      AuditorRole in op.caller.roles
  all op: Operation |
    (op.authenticated = BTrue and op.kind = GetAudit and op.outcome != Success) implies
      op.outcome = NotFound
}
assert FR_023_AuditAuditorOnly { FR_023_AuditAuditorOnly }
check FR_023_AuditAuditorOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-024 applicant cannot mutate post-submission
pred FR_024_NoApplicantMutation {
  all op: Operation |
    (op.outcome = Success and op.kind = PatchStatus) implies
      OfficerRole in op.caller.roles
}
assert FR_024_NoApplicantMutation { FR_024_NoApplicantMutation }
check FR_024_NoApplicantMutation for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AuditCompletenessViolation { some op: Operation | op.outcome = Success and op.kind = PostApplications and no op.audit }
