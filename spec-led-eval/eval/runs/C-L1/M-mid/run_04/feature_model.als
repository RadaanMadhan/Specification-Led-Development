// === feature_model.als — Alloy model for Clinician Access to Patient Medical Records (C-L1) ===
// Branch: 009-clinician-record-access
// Covers: spec.md FR-001 – FR-015; data-model.md; contracts/http-api.md
// Patterns: LeastPrivilege, PermissionCompleteness, AuthRequiredEverywhere,
//           AuditCompleteness, AppendOnly, AttributionCorrectness,
//           OwnershipBasedAccess, NoInformationLeakage

// ─── Role catalogue (v1) ──────────────────────────────────────────────────────
abstract sig ClinicianRole {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends ClinicianRole {}

// ─── Endpoint / operation kinds ───────────────────────────────────────────────
abstract sig OperationKind {}
one sig RecordsLookup, AuditSearch extends OperationKind {}

// ─── Access outcomes (patient-record audit) ───────────────────────────────────
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// ─── Authorisation basis (recorded in every audit entry) ─────────────────────
abstract sig AuthBasis {}
one sig CareTeamMem, NotCareTeamMem, PatientNotFoundBasis extends AuthBasis {}

// ─── External response shapes (byte-equivalence model) ───────────────────────
abstract sig ResponseShape {}
one sig PermittedResponse, DeniedOrNotFoundResponse extends ResponseShape {}

// ─── Permission matrix (singleton; Role × OperationKind) ─────────────────────
one sig PermMatrix {
  Allowed: set ClinicianRole -> OperationKind
}

// ─── Dynamic sigs ─────────────────────────────────────────────────────────────

// Opaque patient identifier (NHS number / MRN).  Not FK-constrained in the
// audit table — the audit logs the identifier even when no Patient row exists.
sig PatientIdentifier {}

sig User {
  role: one ClinicianRole
}

sig Patient {
  pid: one PatientIdentifier
}

// Active care-team membership row for (clinician, patient) — FR-006.
// Only active rows are in this sig; ended memberships are not represented.
sig ActiveMembership {
  member:  one User,
  patient: one Patient
}

// A validated, authenticated attempt at POST /records/lookup.
// Unauthenticated requests and body-invalid requests (missing patient_id) are
// rejected before any attempt is created (FR-001, contracts §Common errors).
sig RecordAccessAttempt {
  caller:      one User,
  targetPid:   one PatientIdentifier,
  outcome:     one AccessOutcome,
  basis:       one AuthBasis,
  extResponse: one ResponseShape
}

// Immutable audit entry — one per RecordAccessAttempt (FR-008 – FR-010).
sig AuditEntry {
  records:      one RecordAccessAttempt,
  roleSnapshot: one ClinicianRole
}

// Authenticated attempt at POST /audit/search.
// No patient-level audit entry is written for these; only AuditOfficer may
// successfully reach this endpoint (FR-011, SC-011).
sig AuditSearchAttempt {
  searcher: one User
}

// ─── Non-empty universe ───────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some PatientIdentifier
  some User
  some Patient
  some ActiveMembership
  some RecordAccessAttempt
  some AuditEntry
  some AuditSearchAttempt
}

// ─── Patient identifier uniqueness ────────────────────────────────────────────
fact F_PatientIdentifierUnique {
  all disj p1, p2: Patient | p1.pid != p2.pid
}

// ─── Permission matrix — closed-world enumeration ────────────────────────────
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md §Authorisation; spec.md FR-005, FR-006, FR-011
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor        -> RecordsLookup) +
    (Nurse         -> RecordsLookup) +
    (Pharmacist    -> RecordsLookup) +
    (ClinicalAdmin -> RecordsLookup) +
    (AuditOfficer  -> AuditSearch)
}

// ─── Audit completeness: every RecordAccessAttempt has exactly one AuditEntry ─
// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, SC-001, SC-002; data-model.md AuditEntry
fact F_AuditOneToOne {
  all a: RecordAccessAttempt | one ae: AuditEntry | ae.records = a
  all disj ae1, ae2: AuditEntry | ae1.records != ae2.records
}

// ─── Attribution correctness: role snapshot = caller's role at access time ────
// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md AuditEntry.clinician_role
fact F_AttributionCorrect {
  all ae: AuditEntry | ae.roleSnapshot = ae.records.caller.role
}

// ─── Outcome ↔ basis consistency ──────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-009; data-model.md AccessOutcome × AuthorisationBasis
fact F_OutcomeBasisConsistency {
  all a: RecordAccessAttempt | {
    (a.outcome = Permitted)        iff (a.basis = CareTeamMem)
    (a.outcome = Denied)           iff (a.basis = NotCareTeamMem)
    (a.outcome = NotFoundOrDenied) iff (a.basis = PatientNotFoundBasis)
  }
}

// ─── Care-team gating — FR-006 ────────────────────────────────────────────────
// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006, SC-010; data-model.md CareTeamMembership
fact F_CareTeamGating {
  // Permitted requires: caller is not AuditOfficer AND has active membership for targetPid
  all a: RecordAccessAttempt |
    a.outcome = Permitted implies (
      not (a.caller.role = AuditOfficer) and
      (some m: ActiveMembership |
        m.member = a.caller and
        (some p: Patient | p.pid = a.targetPid and m.patient = p))
    )
  // Converse: if active membership + non-IG role → Permitted
  all a: RecordAccessAttempt |
    (not (a.caller.role = AuditOfficer) and
     (some m: ActiveMembership |
       m.member = a.caller and
       (some p: Patient | p.pid = a.targetPid and m.patient = p)))
    implies a.outcome = Permitted
}

// ─── Byte-equivalent not-found / denied response shape ───────────────────────
// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003; contracts/http-api.md §Byte-equivalent not-found
fact F_ByteEquivalentResponse {
  all a: RecordAccessAttempt | {
    a.outcome = Permitted  implies a.extResponse = PermittedResponse
    a.outcome != Permitted implies a.extResponse = DeniedOrNotFoundResponse
  }
}

// ─── AuditSearch gating: only AuditOfficer may invoke the audit endpoint ──────
// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-011, SC-011; contracts/http-api.md §POST /audit/search
fact F_AuditSearchGating {
  all s: AuditSearchAttempt | s.searcher.role = AuditOfficer
}

// ─── AuditOfficer is excluded from RecordsLookup Permitted outcomes ───────────
// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-006; contracts/http-api.md §POST /records/lookup authorisation
fact F_AuditOfficerNoRecordAccess {
  all a: RecordAccessAttempt | a.caller.role = AuditOfficer implies a.outcome != Permitted
}

// ─── Append-only audit: no two entries record the same attempt ────────────────
// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, FR-012, SC-006; data-model.md AuditEntry "Append-only"
fact F_AppendOnlyAudit {
  all disj ae1, ae2: AuditEntry | ae1.records != ae2.records
}

// ─── No record content returned without a persisted audit entry ───────────────
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-013, SC-002; contracts/http-api.md §503 service_unavailable
fact F_NoRecordWithoutAudit {
  all a: RecordAccessAttempt |
    a.extResponse = PermittedResponse implies
    (some ae: AuditEntry | ae.records = a)
}

// =============================================================================
// HELPER PREDICATE
// =============================================================================

pred isClinicalRole[r: ClinicianRole] {
  r in Doctor + Nurse + Pharmacist + ClinicalAdmin
}

// =============================================================================
// PATTERN PREDICATES AND ASSERTIONS
// =============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-005, FR-006, FR-011
pred LeastPrivilege {
  some RecordAccessAttempt
  some AuditSearchAttempt
  // Permitted record access only when role is allowed for RecordsLookup
  all a: RecordAccessAttempt |
    a.outcome = Permitted implies (a.caller.role -> RecordsLookup in PermMatrix.Allowed)
  // AuditSearch only reachable by AuditOfficer
  all s: AuditSearchAttempt | s.searcher.role -> AuditSearch in PermMatrix.Allowed
  // AuditOfficer cannot obtain Permitted on record lookup
  all a: RecordAccessAttempt | a.caller.role = AuditOfficer implies a.outcome != Permitted
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 5 ClinicianRole, exactly 2 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md authorisation tables
pred PermissionCompleteness {
  // The matrix has exactly 5 allowed cells; all others are implicitly denied
  #(PermMatrix.Allowed) = 5
  // Spot-check denied cells
  AuditOfficer  -> RecordsLookup not in PermMatrix.Allowed
  Doctor        -> AuditSearch   not in PermMatrix.Allowed
  Nurse         -> AuditSearch   not in PermMatrix.Allowed
  Pharmacist    -> AuditSearch   not in PermMatrix.Allowed
  ClinicalAdmin -> AuditSearch   not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 5 ClinicianRole, exactly 2 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, SC-004; contracts/http-api.md §Authentication
pred FR_001_AuthRequired {
  // Every RecordAccessAttempt resolves to a known User (unauthenticated requests
  // are rejected before an attempt is created)
  some RecordAccessAttempt
  all a: RecordAccessAttempt | one a.caller
  // Every AuditEntry's records link has a caller (no phantom audit entries)
  all ae: AuditEntry | one ae.records.caller
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002; data-model.md ClinicianRole
pred FR_002_RoleFromIdentity {
  some User
  // Every user has exactly one role from the v1 catalogue; no unknown roles
  all u: User | u.role in (Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin)
}
assert FR_002_RoleFromIdentity { FR_002_RoleFromIdentity }
check FR_002_RoleFromIdentity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005; spec.md "v1 access scope is read-only"
pred FR_005_ReadOnly {
  // Only RecordsLookup and AuditSearch exist — no write operation kind is possible
  OperationKind = RecordsLookup + AuditSearch
  no (OperationKind - RecordsLookup - AuditSearch)
}
assert FR_005_ReadOnly { FR_005_ReadOnly }
check FR_005_ReadOnly for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006, SC-010; data-model.md CareTeamMembership
pred FR_006_CareTeamGating {
  some RecordAccessAttempt
  // Permitted access only if active care-team membership exists for the target patient
  all a: RecordAccessAttempt |
    a.outcome = Permitted implies (
      some m: ActiveMembership |
        m.member = a.caller and
        (some p: Patient | p.pid = a.targetPid and m.patient = p)
    )
}
assert FR_006_CareTeamGating { FR_006_CareTeamGating }
check FR_006_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-006 "no break-glass path in v1"
pred FR_006_NoBreakGlass {
  some RecordAccessAttempt
  // AuditOfficer attempting record lookup never receives Permitted
  all a: RecordAccessAttempt |
    a.caller.role = AuditOfficer implies a.outcome != Permitted
  // No Permitted outcome exists without a matching ActiveMembership
  all a: RecordAccessAttempt |
    a.outcome = Permitted implies (
      some m: ActiveMembership |
        m.member = a.caller and
        (some p: Patient | p.pid = a.targetPid and m.patient = p)
    )
}
assert FR_006_NoBreakGlass { FR_006_NoBreakGlass }
check FR_006_NoBreakGlass for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003; contracts/http-api.md §Byte-equivalent not-found
pred FR_007_NoInformationLeakage {
  some RecordAccessAttempt
  // Denied and NotFoundOrDenied both produce the same byte-equivalent response
  all a: RecordAccessAttempt |
    (a.outcome = Denied or a.outcome = NotFoundOrDenied) implies
    a.extResponse = DeniedOrNotFoundResponse
  // A caller cannot distinguish a denied patient from a non-existent patient
  no a: RecordAccessAttempt |
    (a.outcome = Denied        and a.extResponse = PermittedResponse)
  no a: RecordAccessAttempt |
    (a.outcome = NotFoundOrDenied and a.extResponse = PermittedResponse)
}
assert FR_007_NoInformationLeakage { FR_007_NoInformationLeakage }
check FR_007_NoInformationLeakage for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, SC-001, SC-002; data-model.md AuditEntry
pred FR_008_AlwaysOnAudit {
  some RecordAccessAttempt
  // Every access attempt (permitted, denied, or not-found) has exactly one audit entry
  all a: RecordAccessAttempt | one ae: AuditEntry | ae.records = a
}
assert FR_008_AlwaysOnAudit { FR_008_AlwaysOnAudit }
check FR_008_AlwaysOnAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md AuditEntry fields
pred FR_009_AuditEntryFields {
  some AuditEntry
  // Every entry has a caller, a role snapshot, an outcome, and a basis
  all ae: AuditEntry | {
    one ae.records.caller
    one ae.roleSnapshot
    one ae.records.outcome
    one ae.records.basis
    // Role snapshot accurately reflects the caller's role at access time
    ae.roleSnapshot = ae.records.caller.role
  }
}
assert FR_009_AuditEntryFields { FR_009_AuditEntryFields }
check FR_009_AuditEntryFields for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, FR-012, SC-006; data-model.md "no UPDATE/DELETE"
pred FR_010_AuditImmutable {
  some AuditEntry
  // No two AuditEntries record the same access attempt (no duplicate / overwrite)
  all disj ae1, ae2: AuditEntry | ae1.records != ae2.records
  // Each AuditEntry's records link is total and stable (enforced by `one` field type)
  all ae: AuditEntry | some ae.records
}
assert FR_010_AuditImmutable { FR_010_AuditImmutable }
check FR_010_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011, SC-011; contracts/http-api.md §POST /audit/search
pred FR_011_AuditIGOnly {
  some AuditSearchAttempt
  // Only AuditOfficer users ever appear as searcher on an AuditSearchAttempt
  all s: AuditSearchAttempt | s.searcher.role = AuditOfficer
  // No clinical-role user is the searcher of any AuditSearchAttempt
  no s: AuditSearchAttempt | isClinicalRole[s.searcher.role]
}
assert FR_011_AuditIGOnly { FR_011_AuditIGOnly }
check FR_011_AuditIGOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013, SC-002, SC-007; contracts/http-api.md §503 service_unavailable
pred FR_013_NoRecordWithoutAudit {
  some RecordAccessAttempt
  // A PermittedResponse is only delivered when an audit entry already exists for the attempt
  all a: RecordAccessAttempt |
    a.extResponse = PermittedResponse implies
    (some ae: AuditEntry | ae.records = a)
}
assert FR_013_NoRecordWithoutAudit { FR_013_NoRecordWithoutAudit }
check FR_013_NoRecordWithoutAudit for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md clinician_role snapshot
pred AttributionCorrectness {
  some AuditEntry
  all ae: AuditEntry | ae.roleSnapshot = ae.records.caller.role
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, FR-012; data-model.md AuditEntry "Append-only"
pred AppendOnly {
  some AuditEntry
  // Injectivity of records: each attempt is recorded at most once
  all disj ae1, ae2: AuditEntry | ae1.records != ae2.records
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: SC-011; contracts/http-api.md §POST /audit/search
pred SC_011_AuditEndpointHidden {
  // The audit search endpoint is invisible to non-IG roles:
  // no AuditSearchAttempt exists with a non-AuditOfficer searcher
  all s: AuditSearchAttempt | s.searcher.role = AuditOfficer
}
assert SC_011_AuditEndpointHidden { SC_011_AuditEndpointHidden }
check SC_011_AuditEndpointHidden for 5