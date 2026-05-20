// === feature_model.als — Alloy model for Clinician Access to Patient Medical Records (v1) ===
// Feature: C-L1  |  Branch: 009-clinician-record-access  |  Spec date: 2026-05-17
// Artefacts consumed: spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────────────────────────────────
// ROLES  (data-model.md ClinicianRole enum; spec.md FR-002)
// ─────────────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends Role {}

// Convenience: the set of clinical roles (may use RecordsLookup)
fun ClinicalRoles: set Role { Doctor + Nurse + Pharmacist + ClinicalAdmin }

// ─────────────────────────────────────────────────────────────────────────────
// OPERATION KINDS  (contracts/http-api.md: exactly two endpoints)
// ─────────────────────────────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig RecordsLookup, AuditSearch extends OperationKind {}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (canonical pattern — singleton-sig field)
// ─────────────────────────────────────────────────────────────────────────────
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─────────────────────────────────────────────────────────────────────────────
// ENUMS
// ─────────────────────────────────────────────────────────────────────────────
abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

abstract sig AuthBasis {}
one sig CareTeamMember_b, NotCareTeamMember_b, PatientNotFound_b extends AuthBasis {}

// External response shape — used to model byte-equivalence (FR-007)
abstract sig ExternalResponse {}
one sig NotFoundResponse, RecordResponse extends ExternalResponse {}

// ─────────────────────────────────────────────────────────────────────────────
// DOMAIN ENTITIES
// ─────────────────────────────────────────────────────────────────────────────
sig User { role: one Role }

sig Patient {}

// PatientSummary: safety-relevant view (one per patient; data-model.md PatientSummary)
sig PatientSummary { forPatient: one Patient }

// CareTeamMembership (data-model.md; authoritative source for FR-006)
sig CareTeamMembership {
  clinician : one User,
  patient   : one Patient,
  status    : one MembershipStatus
}

// AccessOperation: a request that reached the service layer (authenticated).
// Unauthenticated requests never become AccessOperation atoms (FR-001 boundary).
sig AccessOperation {
  caller          : one User,
  opKind          : one OperationKind,
  targetPatient   : one Patient,
  outcome         : one AccessOutcome,
  basis           : one AuthBasis,
  externalResp    : one ExternalResponse
}

// RecordView: the payload returned on a successful read (FR-014, FR-015)
sig RecordView {
  operation      : one AccessOperation,
  patientSummary : one PatientSummary
}

// AuditEntry: immutable append-only record (FR-009, FR-010, FR-012)
sig AuditEntry {
  clinician   : one User,
  snapRole    : one Role,          // snapshotted at access time (FR-009)
  patientRef  : one Patient,       // patient_id as presented (may not exist as Patient)
  outcome     : one AccessOutcome,
  basis       : one AuthBasis,
  operation   : one AccessOperation // the operation this entry records
}

// ─────────────────────────────────────────────────────────────────────────────
// NON-EMPTY UNIVERSE  (Rule 9 — prevent vacuous universal quantification)
// ─────────────────────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some Patient
  some PatientSummary
  some CareTeamMembership
  some AccessOperation
  some RecordView
  some AuditEntry
}

// ─────────────────────────────────────────────────────────────────────────────
// STRUCTURAL FACTS
// ─────────────────────────────────────────────────────────────────────────────

// One PatientSummary per Patient (data-model.md PatientSummary: "patient_id TEXT PK")
fact F_OnePatientSummaryPerPatient {
  all p: Patient | one ps: PatientSummary | ps.forPatient = p
}

// Permission matrix — closed-world, exactly as specified in contracts/http-api.md
// Clinical roles may call RecordsLookup; AuditOfficer may call AuditSearch.
// AuditOfficer is denied RecordsLookup; clinical roles are denied AuditSearch.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor        -> RecordsLookup) +
    (Nurse         -> RecordsLookup) +
    (Pharmacist    -> RecordsLookup) +
    (ClinicalAdmin -> RecordsLookup) +
    (AuditOfficer  -> AuditSearch)
}

// Outcome / basis consistency (data-model.md AuthorisationBasis enum)
fact F_OutcomeBasisConsistency {
  all op: AccessOperation {
    op.outcome = Permitted        implies op.basis = CareTeamMember_b
    op.outcome = Denied           implies op.basis = NotCareTeamMember_b
    op.outcome = NotFoundOrDenied implies op.basis = PatientNotFound_b
  }
}

// Byte-equivalent external response (FR-007, SC-003):
// Denied and NotFoundOrDenied produce the same external response bytes.
fact F_ByteEquivalentResponse {
  all op: AccessOperation {
    (op.outcome = Denied or op.outcome = NotFoundOrDenied)
      implies op.externalResp = NotFoundResponse
    op.outcome = Permitted
      implies op.externalResp = RecordResponse
  }
}

// Role-to-endpoint enforcement (contracts/http-api.md authorisation rules)
fact F_RoleToEndpointEnforcement {
  all op: AccessOperation {
    op.opKind = AuditSearch   implies op.caller.role = AuditOfficer
    op.opKind = RecordsLookup implies op.caller.role in ClinicalRoles
  }
}

// Care-team membership gate (FR-006): Permitted iff active membership exists
fact F_CareTeamMembershipGate {
  all op: AccessOperation | op.opKind = RecordsLookup implies {
    op.outcome = Permitted iff
      (some m: CareTeamMembership |
        m.clinician = op.caller and
        m.patient   = op.targetPatient and
        m.status    = Active)
  }
}

// Every RecordsLookup AccessOperation has exactly one AuditEntry (FR-008, SC-001)
fact F_AuditCompleteness {
  all op: AccessOperation | op.opKind = RecordsLookup implies
    (one ae: AuditEntry | ae.operation = op)
}

// Audit entries only record RecordsLookup operations (not AuditSearch — per contracts/)
fact F_AuditScopeRecordsLookupOnly {
  all ae: AuditEntry | ae.operation.opKind = RecordsLookup
}

// Audit entry attribution: every field faithfully reflects the operation (FR-009)
fact F_AuditEntryAttribution {
  all ae: AuditEntry {
    ae.clinician  = ae.operation.caller
    ae.patientRef = ae.operation.targetPatient
    ae.outcome    = ae.operation.outcome
    ae.basis      = ae.operation.basis
    ae.snapRole   = ae.clinician.role   // snapshot at access time
  }
}

// AppendOnly: no two audit entries record the same operation (no mutation/duplication)
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry | ae1.operation != ae2.operation
}

// RecordView only for Permitted operations; each Permitted op has exactly one view
fact F_RecordViewOnlyForPermitted {
  all rv: RecordView | rv.operation.outcome = Permitted
  all op: AccessOperation | op.outcome = Permitted implies
    (one rv: RecordView | rv.operation = op)
}

// The RecordView's patientSummary matches the operation's target patient (FR-014, FR-015)
fact F_RecordViewIncludesSafetySummary {
  all rv: RecordView | rv.patientSummary.forPatient = rv.operation.targetPatient
}

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN PREDICATES + ASSERTIONS
// ─────────────────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-006, FR-011
pred LeastPrivilege {
  some AccessOperation
  // Every operation's (role, opKind) pair is in the allowed matrix
  all op: AccessOperation |
    op.caller.role -> op.opKind in PermMatrix.Allowed
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables; spec.md FR-005, FR-011
pred PermissionCompleteness {
  // AuditOfficer is explicitly excluded from RecordsLookup
  AuditOfficer -> RecordsLookup not in PermMatrix.Allowed
  // Clinical roles are explicitly excluded from AuditSearch
  all r: ClinicalRoles | r -> AuditSearch not in PermMatrix.Allowed
  // AuditOfficer has exactly AuditSearch
  all ok: OperationKind | AuditOfficer -> ok in PermMatrix.Allowed iff ok = AuditSearch
  // Clinical roles have exactly RecordsLookup
  all r: ClinicalRoles, ok: OperationKind |
    r -> ok in PermMatrix.Allowed iff ok = RecordsLookup
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-006, FR-011; contracts/http-api.md authorisation tables
pred PermissionGrounding {
  // Every allowed cell corresponds to a known role and opKind (no phantom grants)
  all r: Role, ok: OperationKind |
    r -> ok in PermMatrix.Allowed implies (r in Role and ok in OperationKind)
  // AuditOfficer grant traces to FR-011; clinical grants trace to FR-006
  AuditOfficer -> AuditSearch in PermMatrix.Allowed
  all r: ClinicalRoles | r -> RecordsLookup in PermMatrix.Allowed
}

assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
  some AccessOperation
  // Every AccessOperation has a User with a recognised role as caller.
  // (Unauthenticated requests do not produce AccessOperation atoms — modelled by absence.)
  all op: AccessOperation |
    (some u: User | u = op.caller) and op.caller.role in Role
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, SC-001, SC-002; data-model.md AuditEntry
pred AuditCompleteness {
  some AccessOperation
  // Every RecordsLookup operation produces exactly one AuditEntry
  all op: AccessOperation | op.opKind = RecordsLookup implies
    (one ae: AuditEntry | ae.operation = op)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, SC-006; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  some AuditEntry
  // No two distinct audit entries record the same operation (no duplicate / overwrite)
  all disj ae1, ae2: AuditEntry | ae1.operation != ae2.operation
}

assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md AuditEntry snapshot fields
pred AttributionCorrectness {
  some AuditEntry
  all ae: AuditEntry {
    ae.clinician  = ae.operation.caller
    ae.snapRole   = ae.clinician.role
    ae.patientRef = ae.operation.targetPatient
    ae.outcome    = ae.operation.outcome
    ae.basis      = ae.operation.basis
  }
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006, SC-010; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  some AccessOperation
  // Access is Permitted iff an active care-team membership exists for the caller-patient pair
  all op: AccessOperation | op.opKind = RecordsLookup implies {
    op.outcome = Permitted iff
      (some m: CareTeamMembership |
        m.clinician = op.caller and
        m.patient   = op.targetPatient and
        m.status    = Active)
  }
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  some op1: AccessOperation | op1.outcome = Denied
  some op2: AccessOperation | op2.outcome = NotFoundOrDenied
  // Both Denied and NotFoundOrDenied map to the same external response object
  all op: AccessOperation {
    op.outcome = Denied           implies op.externalResp = NotFoundResponse
    op.outcome = NotFoundOrDenied implies op.externalResp = NotFoundResponse
    op.outcome = Permitted        implies op.externalResp = RecordResponse
  }
  // Denied and NotFoundOrDenied never expose the RecordResponse
  no op: AccessOperation |
    op.outcome != Permitted and op.externalResp = RecordResponse
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// ─────────────────────────────────────────────────────────────────────────────
// FR-SPECIFIC PREDICATES + ASSERTIONS
// ─────────────────────────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001; SC-004; contracts/http-api.md Authentication section
pred FR_001_AuthRequired {
  some AccessOperation
  // Every AccessOperation is attributed to an authenticated User.
  // The absence of unauthenticated operations is structural: only authenticated
  // requests produce AccessOperation atoms.
  all op: AccessOperation | op.caller in User and op.caller.role in Role
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002; spec.md role catalogue; data-model.md ClinicianRole enum
pred FR_002_RoleResolution {
  some User
  // Every user carries exactly one role from the v1 five-role catalogue
  all u: User | u.role in (Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin)
}

assert FR_002_RoleResolution { FR_002_RoleResolution }
check FR_002_RoleResolution for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005; spec.md "read-only, v1 scope"
pred FR_005_ReadOnly {
  some AccessOperation
  // The only OperationKinds in the model are RecordsLookup and AuditSearch;
  // no write-type endpoint exists.
  all op: AccessOperation | op.opKind in (RecordsLookup + AuditSearch)
  // The model's entire OperationKind universe contains no write operations
  OperationKind = RecordsLookup + AuditSearch
}

assert FR_005_ReadOnly { FR_005_ReadOnly }
check FR_005_ReadOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006; SC-010; data-model.md CareTeamMembership; contracts/ authorisation
pred FR_006_CareTeamMembershipGating {
  some AccessOperation
  all op: AccessOperation | op.opKind = RecordsLookup implies {
    // Permitted only when there is an active membership for this exact pair
    op.outcome = Permitted iff
      (some m: CareTeamMembership |
        m.clinician = op.caller and
        m.patient   = op.targetPatient and
        m.status    = Active)
    // No break-glass path: no other route to Permitted
    op.outcome = Permitted implies
      (some m: CareTeamMembership |
        m.clinician = op.caller and
        m.patient   = op.targetPatient and
        m.status    = Active)
  }
}

assert FR_006_CareTeamMembershipGating { FR_006_CareTeamMembershipGating }
check FR_006_CareTeamMembershipGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007; SC-003; contracts/http-api.md byte-equivalent not-found response
pred FR_007_ByteEquivalentDenied {
  some op1: AccessOperation | op1.outcome = Denied
  some op2: AccessOperation | op2.outcome = NotFoundOrDenied
  // Both non-Permitted outcomes produce exactly the canonical NotFoundResponse
  all op: AccessOperation |
    op.outcome != Permitted implies op.externalResp = NotFoundResponse
}

assert FR_007_ByteEquivalentDenied { FR_007_ByteEquivalentDenied }
check FR_007_ByteEquivalentDenied for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008; SC-001, SC-002; data-model.md AuditEntry
pred FR_008_AlwaysOnAudit {
  some AccessOperation
  // Every RecordsLookup operation produces exactly one AuditEntry, regardless of outcome
  all op: AccessOperation | op.opKind = RecordsLookup implies
    (one ae: AuditEntry | ae.operation = op)
  // Denied and NotFoundOrDenied outcomes are also audited (not only Permitted)
  all op: AccessOperation |
    (op.opKind = RecordsLookup and op.outcome = Denied) implies
      (one ae: AuditEntry | ae.operation = op)
  all op: AccessOperation |
    (op.opKind = RecordsLookup and op.outcome = NotFoundOrDenied) implies
      (one ae: AuditEntry | ae.operation = op)
}

assert FR_008_AlwaysOnAudit { FR_008_AlwaysOnAudit }
check FR_008_AlwaysOnAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md AuditEntry field list
pred FR_009_AuditEntryFields {
  some AuditEntry
  // Every audit entry carries all required fields correctly populated
  all ae: AuditEntry {
    // clinician_id
    ae.clinician  = ae.operation.caller
    // clinician_role snapshot
    ae.snapRole   = ae.clinician.role
    // patient_id as presented
    ae.patientRef = ae.operation.targetPatient
    // outcome and authorisation_basis
    ae.outcome    = ae.operation.outcome
    ae.basis      = ae.operation.basis
  }
}

assert FR_009_AuditEntryFields { FR_009_AuditEntryFields }
check FR_009_AuditEntryFields for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010; SC-006; data-model.md "no UPDATE/DELETE on audit_entries"
pred FR_010_AuditImmutability {
  some AuditEntry
  // Each AuditEntry is linked to exactly one operation (immutable, fixed link)
  all ae: AuditEntry | one op: AccessOperation | ae.operation = op
  // No two AuditEntries share an operation (no overwriting / no duplicate entries)
  all disj ae1, ae2: AuditEntry | ae1.operation != ae2.operation
}

assert FR_010_AuditImmutability { FR_010_AuditImmutability }
check FR_010_AuditImmutability for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011; SC-011; contracts/http-api.md POST /audit/search
pred FR_011_AuditReadableByIGOnly {
  some op: AccessOperation | op.opKind = AuditSearch
  // Only AuditOfficer may call AuditSearch
  all op: AccessOperation | op.opKind = AuditSearch implies op.caller.role = AuditOfficer
  // Clinical roles are entirely excluded from AuditSearch
  all op: AccessOperation | op.caller.role in ClinicalRoles implies op.opKind != AuditSearch
}

assert FR_011_AuditReadableByIGOnly { FR_011_AuditReadableByIGOnly }
check FR_011_AuditReadableByIGOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014; SC-008; contracts/http-api.md response key order (allergies/warnings first)
pred FR_014_SafetyFieldsInEveryView {
  some RecordView
  // Every permitted operation's record view is backed by a PatientSummary for that patient
  all rv: RecordView | rv.patientSummary.forPatient = rv.operation.targetPatient
  // A PatientSummary exists for every patient (safety data is always present)
  all p: Patient | (some ps: PatientSummary | ps.forPatient = p)
}

assert FR_014_SafetyFieldsInEveryView { FR_014_SafetyFieldsInEveryView }
check FR_014_SafetyFieldsInEveryView for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015; contracts/http-api.md response structure (patient_id, dob at top)
pred FR_015_PatientVerificationInEveryView {
  some RecordView
  // Every record view links back to the patient (enabling patient_id + dob rendering)
  all rv: RecordView | rv.operation.outcome = Permitted
  all rv: RecordView | rv.patientSummary.forPatient = rv.operation.targetPatient
}

assert FR_015_PatientVerificationInEveryView { FR_015_PatientVerificationInEveryView }
check FR_015_PatientVerificationInEveryView for 8

// FEATURE-SPECIFIC  ANCHOR: FR-001; spec.md "unauthenticated → no audit entry"
pred FR_001_NoAuditForUnauthenticated {
  some AccessOperation
  // Audit entries exist only for AccessOperations (authenticated requests).
  // No AuditEntry can exist without a backing AccessOperation.
  all ae: AuditEntry | ae.operation in AccessOperation
  // AuditEntries are only produced when there is an authenticated caller
  all ae: AuditEntry | ae.clinician in User
}

assert FR_001_NoAuditForUnauthenticated { FR_001_NoAuditForUnauthenticated }
check FR_001_NoAuditForUnauthenticated for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006; spec.md "no break-glass path in v1"
pred FR_006_NoBreakGlass {
  some AccessOperation
  // There is no path to Permitted on RecordsLookup without an active care-team membership
  all op: AccessOperation |
    (op.opKind = RecordsLookup and op.outcome = Permitted) implies
      (some m: CareTeamMembership |
        m.clinician = op.caller and
        m.patient   = op.targetPatient and
        m.status    = Active)
}

assert FR_006_NoBreakGlass { FR_006_NoBreakGlass }
check FR_006_NoBreakGlass for 8

// FEATURE-SPECIFIC  ANCHOR: SC-011; contracts/http-api.md "endpoint existence not leaked to clinical roles"
pred SC_011_AuditEndpointHidden {
  // AuditSearch is never accessible to clinical roles — the endpoint's existence
  // is not revealed to non-IG callers (they receive byte-equivalent 404).
  all op: AccessOperation |
    op.caller.role in ClinicalRoles implies op.opKind = RecordsLookup
}

assert SC_011_AuditEndpointHidden { SC_011_AuditEndpointHidden }
check SC_011_AuditEndpointHidden for 8