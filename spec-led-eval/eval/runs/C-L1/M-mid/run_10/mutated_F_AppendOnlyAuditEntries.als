// === feature_model.als — Alloy model for Clinician Access to Patient Medical Records (v1) ===
// Feature folder : C-L1  (branch 009-clinician-record-access)
// Sources        : spec.md, data-model.md, contracts/http-api.md
// Patterns used  : LeastPrivilege, PermissionCompleteness, PermissionGrounding,
//                  AuthRequiredEverywhere, AuditCompleteness, AppendOnly,
//                  AttributionCorrectness, OwnershipBasedAccess, NoInformationLeakage

// ── Enumerations (one-sig atoms) ──────────────────────────────────────────────

abstract sig ClinicianRole {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends ClinicianRole {}

abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

abstract sig AuthorisationBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthorisationBasis {}

abstract sig OperationKind {}
one sig PostRecordsLookup, PostAuditSearch extends OperationKind {}

// Visible response class — models FR-007 byte-equivalence
abstract sig ResponseClass {}
one sig PermittedResponse, DeniedOrNotFoundResponse extends ResponseClass {}

// Membership status for care-team rows
abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

// ── Permission matrix ────────────────────────────────────────────────────────
// Canonical singleton holding the role × operation allow relation.
// contracts/http-api.md: clinical roles → PostRecordsLookup; audit_officer → PostAuditSearch.

one sig PermMatrix {
  Allowed: set ClinicianRole -> OperationKind
}

// ── Core domain entities ─────────────────────────────────────────────────────

// Every authenticated caller maps to exactly one role (data-model.md users table).
sig User {
  role: one ClinicianRole
}

// Patients identified by opaque id (data-model.md patients table).
sig Patient {}

// Care-team membership: asserted by the host product (data-model.md care_team_memberships).
sig CareTeamMembership {
  clinician : one User,
  patient   : one Patient,
  status    : one MembershipStatus
}

// An authenticated Operation that has reached the service layer.
// Unauthenticated requests never produce an Operation atom (FR-001).
sig Operation {
  caller        : one User,
  opKind        : one OperationKind,
  targetPatient : lone Patient,     // present when the patient exists; absent otherwise
  outcome       : one AccessOutcome,
  basis         : one AuthorisationBasis
}

// Immutable audit record — one per Operation (FR-009, FR-010).
sig AuditEntry {
  forOperation  : one Operation,
  snapshotRole  : one ClinicianRole   // role captured at access time (FR-009 snapshot)
}

// External response wrapping an Operation (models FR-007 byte-equivalence).
sig OperationResponse {
  forOp      : one Operation,
  respClass  : one ResponseClass
}

// ── F_NonEmptyUniverse ───────────────────────────────────────────────────────
// Ensures dynamic sigs are non-empty so all/some quantifiers are non-vacuous.

fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some Operation
  some AuditEntry
  some OperationResponse
}

// ── Named facts encoding structural invariants ───────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation table; spec.md FR-006, FR-011
fact F_LeastPrivilege {
  // Every authenticated operation's (role, opKind) pair must appear in the permission matrix.
  all op: Operation |
    (op.caller.role -> op.opKind) in PermMatrix.Allowed
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table (5 roles × 2 ops)
fact F_PermissionMatrix {
  // Closed-world encoding: exactly the cells below are allowed; all others denied.
  PermMatrix.Allowed =
    (Doctor        -> PostRecordsLookup) +
    (Nurse         -> PostRecordsLookup) +
    (Pharmacist    -> PostRecordsLookup) +
    (ClinicalAdmin -> PostRecordsLookup) +
    (AuditOfficer  -> PostAuditSearch)
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md care_team_memberships
fact F_CareTeamGating {
  // A permitted PostRecordsLookup access requires an active care-team membership.
  all op: Operation |
    (op.opKind = PostRecordsLookup and op.outcome = Permitted) implies
    (some m: CareTeamMembership |
       m.clinician = op.caller and
       m.patient   = op.targetPatient and
       m.status    = Active)
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-006; contracts/http-api.md "Patient exists AND care-team"
fact F_OutcomeBasisConsistency {
  // Outcome and authorisation_basis are jointly consistent on every Operation.
  all op: Operation | {
    op.outcome = Permitted        implies op.basis = CareTeamMember
    op.outcome = Denied           implies op.basis = NotCareTeamMember
    op.outcome = NotFoundOrDenied implies op.basis = PatientNotFound
  }
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-006; contracts/http-api.md behaviour step 3
fact F_PermittedHasPatient {
  // A permitted access must have resolved to a real patient.
  all op: Operation |
    op.outcome = Permitted implies (one p: Patient | op.targetPatient = p)
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008; data-model.md AuditEntry (always-on)
fact F_AlwaysOnAudit {
  // Every Operation produces at least one AuditEntry.
  all op: Operation | some ae: AuditEntry | ae.forOperation = op
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010; data-model.md "Append-only: no UPDATE/DELETE"
fact F_AppendOnlyAuditEntries { /* MUTATED — body cleared by validator */ }

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md AuditEntry snapshotRole
fact F_AttributionCorrectness {
  // The snapshotted role in every AuditEntry matches the role of the actual caller.
  all ae: AuditEntry | ae.snapshotRole = ae.forOperation.caller.role
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007; contracts/http-api.md byte-equivalent 404
fact F_ByteEquivalentDenied {
  // Denied and NotFoundOrDenied outcomes produce the same DeniedOrNotFoundResponse;
  // only Permitted outcomes produce a PermittedResponse.
  all r: OperationResponse | {
    r.forOp.outcome = Permitted implies
      r.respClass = PermittedResponse
    (r.forOp.outcome = Denied or r.forOp.outcome = NotFoundOrDenied) implies
      r.respClass = DeniedOrNotFoundResponse
  }
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-007; contracts/http-api.md "single canonical not_found"
fact F_ResponseCoverage {
  // Every Operation has exactly one OperationResponse.
  all op: Operation | one r: OperationResponse | r.forOp = op
  all disj r1, r2: OperationResponse | r1.forOp != r2.forOp
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-011; contracts/http-api.md POST /audit/search authorisation
fact F_AuditIGOnly {
  // Only audit_officers may invoke PostAuditSearch.
  all op: Operation |
    op.opKind = PostAuditSearch implies op.caller.role = AuditOfficer
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-001; contracts/http-api.md authentication boundary
fact F_AuthRequiredEverywhere {
  // All Operations have a resolved caller — unauthenticated requests never create Operation atoms.
  // Encoded structurally: every Operation.caller is a well-formed User.
  all op: Operation | op.caller in User
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-013; contracts/http-api.md 503 SLA path
fact F_AuditSyncWithAccess {
  // No Operation is left unaudited: the set of Operations and the set of audited Operations coincide.
  // (The 503 path where audit fails is not a valid committed state; we model the committed state only.)
  Operation = AuditEntry.forOperation
}

// ── Pattern predicates (mirror the catalogue) ────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation table; spec.md FR-006, FR-011
pred LeastPrivilege {
  some Operation
  all op: Operation |
    (op.caller.role -> op.opKind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 5 ClinicianRole, exactly 2 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md (5 roles × 2 ops, all cells defined)
pred PermissionCompleteness {
  // Every role × opKind cell has a verdict: either (role->op) in Allowed or not.
  // The fact F_PermissionMatrix closes the world completely; assert no cell is undefined.
  PermMatrix.Allowed =
    (Doctor        -> PostRecordsLookup) +
    (Nurse         -> PostRecordsLookup) +
    (Pharmacist    -> PostRecordsLookup) +
    (ClinicalAdmin -> PostRecordsLookup) +
    (AuditOfficer  -> PostAuditSearch)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 5 ClinicianRole, exactly 2 OperationKind

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-006 (clinical access), FR-011 (IG access)
pred PermissionGrounding {
  // Every allow entry traces to a documented FR.
  // Clinical roles -> PostRecordsLookup: grounded in FR-006.
  // AuditOfficer   -> PostAuditSearch:   grounded in FR-011.
  // Assert that AuditOfficer is NOT in the allowed set for PostRecordsLookup.
  some Operation
  AuditOfficer -> PostRecordsLookup not in PermMatrix.Allowed
  Doctor -> PostAuditSearch         not in PermMatrix.Allowed
  Nurse  -> PostAuditSearch         not in PermMatrix.Allowed
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8 but exactly 5 ClinicianRole, exactly 2 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth boundary
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation | op.caller in User
  // No Operation exists without a valid caller
  no op: Operation | no op.caller
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, SC-001, SC-002; data-model.md AuditEntry
pred AuditCompleteness {
  some Operation
  all op: Operation | (some ae: AuditEntry | ae.forOperation = op)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, SC-006; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  some AuditEntry
  all disj ae1, ae2: AuditEntry | ae1.forOperation != ae2.forOperation
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md snapshotted clinician_role
pred AttributionCorrectness {
  some AuditEntry
  all ae: AuditEntry | ae.snapshotRole = ae.forOperation.caller.role
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md care_team_memberships
pred OwnershipBasedAccess {
  some op: Operation | op.opKind = PostRecordsLookup and op.outcome = Permitted
  all op: Operation |
    (op.opKind = PostRecordsLookup and op.outcome = Permitted) implies
    (some m: CareTeamMembership |
       m.clinician = op.caller and
       m.patient   = op.targetPatient and
       m.status    = Active)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003, SC-011; contracts/http-api.md 404
pred NoInformationLeakage {
  some r: OperationResponse |
    r.forOp.outcome = Denied or r.forOp.outcome = NotFoundOrDenied
  all r: OperationResponse |
    (r.forOp.outcome = Denied or r.forOp.outcome = NotFoundOrDenied) implies
    r.respClass = DeniedOrNotFoundResponse
  all r: OperationResponse |
    r.forOp.outcome = Permitted implies r.respClass = PermittedResponse
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ── Feature-specific FR predicates ──────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001; contracts/http-api.md "401 before any handler logic"
pred FR_001_AuthRequired {
  // All Operations resolve to a well-formed User; no caller-less operations.
  some Operation
  all op: Operation | one u: User | op.caller = u
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002; data-model.md users.clinician_role (one per user)
pred FR_002_OneRolePerUser {
  some User
  all u: User | one r: ClinicianRole | u.role = r
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005; spec.md "v1 access scope is read-only"
pred FR_005_ReadOnlyScope {
  // In v1, only PostRecordsLookup and PostAuditSearch exist. No write OperationKind exists.
  some Operation
  all op: Operation | op.opKind in (PostRecordsLookup + PostAuditSearch)
}
assert FR_005_ReadOnlyScope { FR_005_ReadOnlyScope }
check FR_005_ReadOnlyScope for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006; spec.md "care-team membership required for permitted access"
pred FR_006_CareTeamGating {
  some op: Operation | op.opKind = PostRecordsLookup and op.outcome = Permitted
  all op: Operation |
    (op.opKind = PostRecordsLookup and op.outcome = Permitted) implies
    (some m: CareTeamMembership |
       m.clinician = op.caller and
       m.patient   = op.targetPatient and
       m.status    = Active)
}
assert FR_006_CareTeamGating { FR_006_CareTeamGating }
check FR_006_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007; contracts/http-api.md byte-equivalent not-found
pred FR_007_ByteEquivalentDenied {
  some r: OperationResponse |
    r.forOp.outcome = Denied or r.forOp.outcome = NotFoundOrDenied
  all r: OperationResponse |
    (r.forOp.outcome = Denied or r.forOp.outcome = NotFoundOrDenied) implies
    r.respClass = DeniedOrNotFoundResponse
  // Crucially: a Permitted outcome does NOT produce DeniedOrNotFoundResponse
  all r: OperationResponse |
    r.respClass = PermittedResponse implies r.forOp.outcome = Permitted
}
assert FR_007_ByteEquivalentDenied { FR_007_ByteEquivalentDenied }
check FR_007_ByteEquivalentDenied for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008; spec.md SC-001, SC-002 "always-on audit"
pred FR_008_AlwaysOnAudit {
  some Operation
  all op: Operation | (some ae: AuditEntry | ae.forOperation = op)
}
assert FR_008_AlwaysOnAudit { FR_008_AlwaysOnAudit }
check FR_008_AlwaysOnAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md AuditEntry snapshotted fields
pred FR_009_SnapshotAttribution {
  some AuditEntry
  all ae: AuditEntry | ae.snapshotRole = ae.forOperation.caller.role
}
assert FR_009_SnapshotAttribution { FR_009_SnapshotAttribution }
check FR_009_SnapshotAttribution for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010; spec.md SC-006 "immutable: no UPDATE/DELETE"
pred FR_010_AuditImmutability {
  some AuditEntry
  // No two audit entries record the same operation (no overwrite = immutability structural proxy)
  all disj ae1, ae2: AuditEntry | ae1.forOperation != ae2.forOperation
}
assert FR_010_AuditImmutability { FR_010_AuditImmutability }
check FR_010_AuditImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011; contracts/http-api.md POST /audit/search authorisation
pred FR_011_AuditIGOnly {
  some op: Operation | op.opKind = PostAuditSearch
  all op: Operation |
    op.opKind = PostAuditSearch implies op.caller.role = AuditOfficer
}
assert FR_011_AuditIGOnly { FR_011_AuditIGOnly }
check FR_011_AuditIGOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013; spec.md SC-007; contracts/http-api.md 2-second SLA
pred FR_013_AuditSyncWithAccess {
  // In a committed state, every Operation has an AuditEntry (SLA breach → 503 + rollback)
  some Operation
  all op: Operation | op in AuditEntry.forOperation
}
assert FR_013_AuditSyncWithAccess { FR_013_AuditSyncWithAccess }
check FR_013_AuditSyncWithAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006, FR-007; denied access must not reveal patient existence
pred FR_DeniedNoCareTeamImpliesNoRecord {
  // If a clinician has outcome = Denied, no patient summary is exposed (respClass ≠ PermittedResponse)
  some r: OperationResponse | r.forOp.outcome = Denied
  all r: OperationResponse |
    r.forOp.outcome = Denied implies r.respClass != PermittedResponse
}
assert FR_DeniedNoCareTeamImpliesNoRecord { FR_DeniedNoCareTeamImpliesNoRecord }
check FR_DeniedNoCareTeamImpliesNoRecord for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006; spec.md "membership lookup on every request"
pred FR_NoCareTeamImpliesNoPermit {
  // If a clinician has no active membership for a patient, they cannot get Permitted
  all op: Operation |
    (op.opKind = PostRecordsLookup and
     no m: CareTeamMembership |
       (m.clinician = op.caller and m.patient = op.targetPatient and m.status = Active))
    implies op.outcome != Permitted
}
assert FR_NoCareTeamImpliesNoPermit { FR_NoCareTeamImpliesNoPermit }
check FR_NoCareTeamImpliesNoPermit for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-011, SC-011; contracts/http-api.md clinical roles get 404 on /audit/search
pred FR_ClinicalRoleDeniedAuditSearch {
  // No clinical-role caller ever has opKind = PostAuditSearch
  some User
  all op: Operation |
    (op.caller.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin)) implies
    op.opKind != PostAuditSearch
}
assert FR_ClinicalRoleDeniedAuditSearch { FR_ClinicalRoleDeniedAuditSearch }
check FR_ClinicalRoleDeniedAuditSearch for 8 but exactly 5 ClinicianRole, exactly 2 OperationKind

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-002; data-model.md ClinicianRole enum (5 values)
pred FR_RoleCatalogueComplete {
  // All five roles exist as distinct atoms in ClinicianRole
  Doctor != Nurse
  Doctor != Pharmacist
  Doctor != AuditOfficer
  Doctor != ClinicalAdmin
  Nurse  != Pharmacist
  Nurse  != AuditOfficer
  Nurse  != ClinicalAdmin
  Pharmacist != AuditOfficer
  Pharmacist != ClinicalAdmin
  AuditOfficer != ClinicalAdmin
}
assert FR_RoleCatalogueComplete { FR_RoleCatalogueComplete }
check FR_RoleCatalogueComplete for 8 but exactly 5 ClinicianRole

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AppendOnlyViolation { some disj ae1, ae2: AuditEntry | ae1.forOperation = ae2.forOperation }
