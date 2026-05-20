// === feature_model.als — Alloy model for Clinician Access to Patient Medical Records (C-L1) ===
// Feature branch: 009-clinician-record-access
// Derived from: spec.md, data-model.md, contracts/http-api.md

// ═══════════════════════════════════════════════════════════════════════════════
// ENUMERATIONS
// ═══════════════════════════════════════════════════════════════════════════════

abstract sig ClinicianRole {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends ClinicianRole {}

abstract sig OperationKind {}
one sig RecordsLookup, AuditSearch extends OperationKind {}

abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

abstract sig AuthBasis {}
one sig CareTeamMemberBasis, NotCareTeamMemberBasis, PatientNotFoundBasis extends AuthBasis {}

abstract sig ResponseKind {}
one sig OkResponse, NotFoundResponse extends ResponseKind {}

// Response sections — used for clinical-safety ordering in record views (FR-014, FR-015)
abstract sig ResponseSection {}
one sig PatientIdSection, DateOfBirthSection, NameSection,
         AllergiesSection, KeyWarningsSection,
         MedicationsSection, EncountersSection extends ResponseSection {}

abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

// ═══════════════════════════════════════════════════════════════════════════════
// PERMISSION MATRIX  (contracts/http-api.md authorisation tables)
// ═══════════════════════════════════════════════════════════════════════════════

// Singleton that carries the (Role × OperationKind) allowed relation.
one sig PermMatrix { Allowed: set ClinicianRole -> OperationKind }

// ═══════════════════════════════════════════════════════════════════════════════
// DOMAIN SIGS
// ═══════════════════════════════════════════════════════════════════════════════

sig Clinician {
  role: one ClinicianRole
}

sig Patient {}

// An opaque patient identifier as presented in a request.
// resolves is lone: a known patient, or no patient (non-existent identifier).
sig PatientRef {
  resolves: lone Patient
}

// Care-team membership row as supplied by the host product (data-model.md).
sig CareTeamMembership {
  member:     one Clinician,
  forPatient: one Patient,
  status:     one MembershipStatus
}

// Immutable audit-entry record (data-model.md AuditEntry, FR-009).
sig AuditEntry {
  forClinician:  one Clinician,
  snapshotRole:  one ClinicianRole,      // snapshotted at access time
  forPatientRef: one PatientRef,
  outcome:       one AccessOutcome,
  authBasis:     one AuthBasis
}

// An authenticated access attempt that has reached the service layer.
// auditEntry is lone: the SLA-breach path (FR-013) may produce no audit entry.
sig AccessAttempt {
  caller:     one Clinician,
  kind:       one OperationKind,
  patientRef: one PatientRef,
  outcome:    one AccessOutcome,
  authBasis:  one AuthBasis,
  auditEntry: lone AuditEntry,
  response:   one ResponseKind
}

// A record view produced for a Permitted outcome (FR-014, FR-015).
// 'sectionBefore' encodes the strict ordering of response sections.
sig RecordView {
  forAttempt:    one AccessAttempt,
  sectionBefore: ResponseSection -> ResponseSection   // transitive partial order
}

// ═══════════════════════════════════════════════════════════════════════════════
// NON-EMPTY UNIVERSE
// ═══════════════════════════════════════════════════════════════════════════════

fact F_NonEmptyUniverse {
  some Clinician
  some Patient
  some PatientRef
  some CareTeamMembership
  some AuditEntry
  some AccessAttempt
  some RecordView
}

// ═══════════════════════════════════════════════════════════════════════════════
// NAMED FACTS — structural invariants
// ═══════════════════════════════════════════════════════════════════════════════

// ─── Permission matrix (closed-world) ────────────────────────────────────────
// contracts/http-api.md: clinical roles → RecordsLookup; AuditOfficer → AuditSearch only.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor       -> RecordsLookup) +
    (Nurse        -> RecordsLookup) +
    (Pharmacist   -> RecordsLookup) +
    (ClinicalAdmin -> RecordsLookup) +
    (AuditOfficer -> AuditSearch)
}

// ─── Every AccessAttempt uses only a permitted (role, operation) pair ─────────
// spec.md FR-006, FR-011; contracts/http-api.md authorisation section.
fact F_LeastPrivilege {
  all a: AccessAttempt |
    a.caller.role -> a.kind in PermMatrix.Allowed
}

// ─── Care-team gating (FR-006): permitted iff active membership exists ─────────
// spec.md FR-006 / SC-010; data-model.md CareTeamMembership.
fact F_CareTeamGating {
  all a: AccessAttempt |
    a.kind = RecordsLookup implies (
      a.outcome = Permitted iff (
        some m: CareTeamMembership |
          m.member = a.caller and
          m.status = Active and
          some p: Patient |
            p = a.patientRef.resolves and m.forPatient = p
      )
    )
}

// ─── Auth-basis consistency with outcome ─────────────────────────────────────
// spec.md FR-008, FR-009; data-model.md AuthorisationBasis enum.
fact F_AuthBasisConsistency {
  all a: AccessAttempt |
    a.kind = RecordsLookup implies (
      (a.outcome = Permitted           implies a.authBasis = CareTeamMemberBasis)   and
      (a.outcome = Denied              implies a.authBasis = NotCareTeamMemberBasis) and
      (a.outcome = NotFoundOrDenied    implies a.authBasis = PatientNotFoundBasis)
    )
  all a: AccessAttempt |
    a.kind = RecordsLookup and a.outcome = NotFoundOrDenied implies
      (no a.patientRef.resolves)
  all a: AccessAttempt |
    a.kind = RecordsLookup and a.outcome = Denied implies
      (some a.patientRef.resolves)
}

// ─── Byte-equivalent not-found response (FR-007) ─────────────────────────────
// spec.md FR-007 / SC-003; contracts/http-api.md "Byte-equivalent not-found response".
fact F_ByteEquivalentResponse {
  // Denied and not-found-or-denied both yield NotFoundResponse
  all a: AccessAttempt |
    (a.outcome = Denied or a.outcome = NotFoundOrDenied) implies
      a.response = NotFoundResponse
  // Only permitted accesses yield OkResponse
  all a: AccessAttempt |
    a.outcome = Permitted implies a.response = OkResponse
  // AuditSearch non-officer callers get NotFoundResponse too
  all a: AccessAttempt |
    a.kind = AuditSearch implies a.response = NotFoundResponse or a.response = OkResponse
}

// ─── Always-on audit (FR-008): every non-SLA-breach attempt has an audit entry
// spec.md FR-008 / SC-001 / SC-002; data-model.md AuditEntry.
fact F_AlwaysOnAudit {
  // For normal (non-service-unavailable) outcomes, exactly one audit entry exists.
  // Model: a Permitted or Denied or NotFoundOrDenied attempt has exactly one entry.
  all a: AccessAttempt |
    (a.outcome = Permitted or a.outcome = Denied or a.outcome = NotFoundOrDenied) implies
      (one e: AuditEntry | a.auditEntry = e)
}

// ─── Audit entries are owned by exactly one AccessAttempt (no phantom entries) ─
// spec.md SC-002; data-model.md append-only semantics.
fact F_AuditEntryOwnership {
  all e: AuditEntry | one a: AccessAttempt | a.auditEntry = e
}

// ─── Attribution correctness (FR-009): audit entry matches its attempt ─────────
// spec.md FR-009; data-model.md AuditEntry snapshot fields.
fact F_AuditAttributionCorrectness {
  all a: AccessAttempt, e: AuditEntry |
    a.auditEntry = e implies (
      e.forClinician  = a.caller     and
      e.snapshotRole  = a.caller.role and
      e.forPatientRef = a.patientRef  and
      e.outcome       = a.outcome     and
      e.authBasis     = a.authBasis
    )
}

// ─── Append-only audit: no two attempts share an audit entry ─────────────────
// spec.md FR-010 / SC-006; data-model.md "no UPDATE/DELETE on audit_entries".
fact F_AppendOnlyAuditEntries { /* MUTATED — body cleared by validator */ }

// ─── IG-only audit access (FR-011): AuditSearch callers must be AuditOfficer ──
// spec.md FR-011 / SC-011; contracts/http-api.md /audit/search authorisation.
fact F_IGOnlyAuditAccess {
  all a: AccessAttempt |
    a.kind = AuditSearch implies a.caller.role = AuditOfficer
}

// ─── Record views exist only for permitted attempts (FR-005, read-only) ────────
// spec.md FR-005; contracts/http-api.md "200 OK only for permitted".
fact F_RecordViewOnlyForPermitted {
  all rv: RecordView |
    rv.forAttempt.outcome = Permitted and rv.forAttempt.kind = RecordsLookup
  // Every permitted RecordsLookup attempt has exactly one RecordView
  all a: AccessAttempt |
    (a.kind = RecordsLookup and a.outcome = Permitted) implies
      (one rv: RecordView | rv.forAttempt = a)
}

// ─── Clinical-safety response ordering: allergies & warnings before medications
// spec.md FR-014 / SC-008; contracts/http-api.md fixed JSON key order.
fact F_AllergiesAndWarningsFirst {
  all rv: RecordView {
    AllergiesSection  -> MedicationsSection in rv.sectionBefore
    AllergiesSection  -> EncountersSection  in rv.sectionBefore
    KeyWarningsSection -> MedicationsSection in rv.sectionBefore
    KeyWarningsSection -> EncountersSection  in rv.sectionBefore
  }
}

// ─── Patient-verification block first: id and DoB before allergies/medications
// spec.md FR-015; contracts/http-api.md key ordering assertion.
fact F_PatientVerificationBlockFirst {
  all rv: RecordView {
    PatientIdSection    -> AllergiesSection   in rv.sectionBefore
    PatientIdSection    -> KeyWarningsSection  in rv.sectionBefore
    PatientIdSection    -> MedicationsSection  in rv.sectionBefore
    PatientIdSection    -> EncountersSection   in rv.sectionBefore
    DateOfBirthSection  -> AllergiesSection   in rv.sectionBefore
    DateOfBirthSection  -> KeyWarningsSection  in rv.sectionBefore
    DateOfBirthSection  -> MedicationsSection  in rv.sectionBefore
    DateOfBirthSection  -> EncountersSection   in rv.sectionBefore
  }
}

// ─── sectionBefore is acyclic (it is a strict partial order) ─────────────────
fact F_SectionOrderAcyclic {
  all rv: RecordView | no s: ResponseSection | s in s.^(rv.sectionBefore)
}

// ─── Unique care-team membership per (clinician, patient, status pair scope) ──
// data-model.md composite PK (clinician_id, patient_id, episode_of_care_id).
// Modelled: for any clinician-patient pair, at most one active membership.
fact F_AtMostOneActiveMembership {
  all disj m1, m2: CareTeamMembership |
    (m1.member = m2.member and m1.forPatient = m2.forPatient) implies
      not (m1.status = Active and m2.status = Active)
}

// ─── AuditSearch yields no record view (IG endpoint returns audit list, not records)
fact F_AuditSearchNoRecordView {
  all rv: RecordView | rv.forAttempt.kind != AuditSearch
}

// ─── PatientRef for a permitted attempt must resolve to a real patient ─────────
// spec.md FR-006; contracts/http-api.md behaviour section step 3.
fact F_PermittedRefResolvesToPatient {
  all a: AccessAttempt |
    a.outcome = Permitted implies (some a.patientRef.resolves)
}

// ═══════════════════════════════════════════════════════════════════════════════
// PREDICATES
// ═══════════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-006, FR-011
pred LeastPrivilege {
  some AccessAttempt  // universe is non-vacuous
  // No clinical role can invoke AuditSearch
  no a: AccessAttempt |
    a.kind = AuditSearch and a.caller.role != AuditOfficer
  // AuditOfficer cannot invoke RecordsLookup
  no a: AccessAttempt |
    a.kind = RecordsLookup and a.caller.role = AuditOfficer
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 5 ClinicianRole, exactly 2 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables
pred PermissionCompleteness {
  // Every (role, operation) cell is either explicitly allowed or implicitly denied.
  // Closed-world: PermMatrix.Allowed is completely enumerated.
  PermMatrix.Allowed =
    (Doctor -> RecordsLookup) + (Nurse -> RecordsLookup) +
    (Pharmacist -> RecordsLookup) + (ClinicalAdmin -> RecordsLookup) +
    (AuditOfficer -> AuditSearch)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 5 ClinicianRole, exactly 2 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
  // Every AccessAttempt has a caller — unauthenticated requests never reach this layer.
  // The model encodes this structurally: AccessAttempt.caller is 'one Clinician'.
  // Assert that every attempt has a non-empty caller (structurally guaranteed but explicitly checked).
  some AccessAttempt
  all a: AccessAttempt | one a.caller
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, FR-009; data-model.md UNIQUE on audit_entries.id
pred AuditCompleteness {
  some AccessAttempt
  // Every permitted/denied/not-found attempt has exactly one audit entry.
  all a: AccessAttempt |
    (a.outcome = Permitted or a.outcome = Denied or a.outcome = NotFoundOrDenied) implies
      (one e: AuditEntry | a.auditEntry = e)
  // No audit entry is shared between two attempts.
  all disj a1, a2: AccessAttempt |
    (some a1.auditEntry and some a2.auditEntry) implies a1.auditEntry != a2.auditEntry
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, SC-006; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  some AuditEntry
  // Each AuditEntry belongs to exactly one AccessAttempt — no entry is ever "reassigned".
  all e: AuditEntry | one a: AccessAttempt | a.auditEntry = e
  // No two AccessAttempts share an audit entry (no overwriting).
  all disj a1, a2: AccessAttempt |
    (some a1.auditEntry and some a2.auditEntry) implies a1.auditEntry != a2.auditEntry
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md AuditEntry snapshot fields
pred AttributionCorrectness {
  some AuditEntry
  all a: AccessAttempt, e: AuditEntry |
    a.auditEntry = e implies (
      e.forClinician = a.caller and
      e.snapshotRole = a.caller.role and
      e.forPatientRef = a.patientRef and
      e.outcome = a.outcome and
      e.authBasis = a.authBasis
    )
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006, SC-010; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  some AccessAttempt
  // Permitted access implies an active care-team membership exists.
  all a: AccessAttempt |
    (a.kind = RecordsLookup and a.outcome = Permitted) implies (
      some m: CareTeamMembership |
        m.member = a.caller and
        m.status = Active and
        some p: Patient |
          p = a.patientRef.resolves and m.forPatient = p
    )
  // Absent active membership implies access is not permitted.
  all a: AccessAttempt |
    a.kind = RecordsLookup implies (
      (no m: CareTeamMembership |
        m.member = a.caller and m.status = Active and
        some p: Patient | p = a.patientRef.resolves and m.forPatient = p)
        implies a.outcome != Permitted
    )
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003, SC-011; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  some AccessAttempt
  // Denied and not-found-or-denied yield identical response kinds.
  all a: AccessAttempt |
    a.outcome = Denied implies a.response = NotFoundResponse
  all a: AccessAttempt |
    a.outcome = NotFoundOrDenied implies a.response = NotFoundResponse
  // Non-AuditOfficer calling AuditSearch also gets NotFoundResponse.
  all a: AccessAttempt |
    (a.kind = AuditSearch and a.caller.role != AuditOfficer) implies
      a.response = NotFoundResponse
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ─── Feature-specific predicates ─────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  // All access attempts have a resolved authenticated caller with a valid role.
  some AccessAttempt
  all a: AccessAttempt | one a.caller and a.caller.role in ClinicianRole
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_RoleResolution {
  // Every clinician has exactly one role from the v1 catalogue.
  some Clinician
  all c: Clinician | one c.role
  all c: Clinician |
    c.role in (Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin)
}

assert FR_002_RoleResolution { FR_002_RoleResolution }
check FR_002_RoleResolution for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_ReadOnly {
  // Only RecordsLookup (read) and AuditSearch operations exist.
  // No write-surface operations are in scope.
  some AccessAttempt
  all a: AccessAttempt | a.kind in (RecordsLookup + AuditSearch)
}

assert FR_005_ReadOnly { FR_005_ReadOnly }
check FR_005_ReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_CareTeamGating {
  some AccessAttempt
  // Permitted iff active membership
  all a: AccessAttempt |
    a.kind = RecordsLookup implies (
      a.outcome = Permitted iff (
        some m: CareTeamMembership |
          m.member = a.caller and m.status = Active and
          some p: Patient | p = a.patientRef.resolves and m.forPatient = p
      )
    )
}

assert FR_006_CareTeamGating { FR_006_CareTeamGating }
check FR_006_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_ByteEquivalentResponse {
  some AccessAttempt
  all a: AccessAttempt |
    (a.outcome = Denied or a.outcome = NotFoundOrDenied) implies
      a.response = NotFoundResponse
  all a: AccessAttempt |
    a.outcome = Permitted implies a.response = OkResponse
}

assert FR_007_ByteEquivalentResponse { FR_007_ByteEquivalentResponse }
check FR_007_ByteEquivalentResponse for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_AlwaysOnAudit {
  some AccessAttempt
  all a: AccessAttempt |
    (a.outcome = Permitted or a.outcome = Denied or a.outcome = NotFoundOrDenied) implies
      (one e: AuditEntry | a.auditEntry = e)
}

assert FR_008_AlwaysOnAudit { FR_008_AlwaysOnAudit }
check FR_008_AlwaysOnAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_AuditFields {
  // Every audit entry has all required fields populated (structurally enforced by 'one' multiplicity)
  // and attribution matches the attempt it records.
  some AuditEntry
  all e: AuditEntry {
    one e.forClinician
    one e.snapshotRole
    one e.forPatientRef
    one e.outcome
    one e.authBasis
  }
  // Attribution correctness (snapshot semantics)
  all a: AccessAttempt, e: AuditEntry |
    a.auditEntry = e implies (
      e.forClinician  = a.caller and
      e.snapshotRole  = a.caller.role and
      e.forPatientRef = a.patientRef
    )
}

assert FR_009_AuditFields { FR_009_AuditFields }
check FR_009_AuditFields for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010; data-model.md "no UPDATE/DELETE on audit_entries"
pred FR_010_AuditImmutable {
  // No two AccessAttempts reference the same AuditEntry (no reuse / overwrite).
  some AuditEntry
  all disj a1, a2: AccessAttempt |
    (some a1.auditEntry and some a2.auditEntry) implies a1.auditEntry != a2.auditEntry
  // Every AuditEntry has exactly one owning AccessAttempt.
  all e: AuditEntry | one a: AccessAttempt | a.auditEntry = e
}

assert FR_010_AuditImmutable { FR_010_AuditImmutable }
check FR_010_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011; contracts/http-api.md /audit/search authorisation
pred FR_011_IGOnlyAuditAccess {
  some AccessAttempt
  // Only audit_officer may invoke AuditSearch
  all a: AccessAttempt |
    a.kind = AuditSearch implies a.caller.role = AuditOfficer
  // Clinical roles never successfully invoke AuditSearch
  no a: AccessAttempt |
    a.kind = AuditSearch and
    a.caller.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}

assert FR_011_IGOnlyAuditAccess { FR_011_IGOnlyAuditAccess }
check FR_011_IGOnlyAuditAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013; contracts/http-api.md 503 behaviour
pred FR_013_NoRecordWithoutAudit {
  // Every RecordView (record observed by a clinician) has a corresponding audit entry.
  some RecordView
  all rv: RecordView | some rv.forAttempt.auditEntry
}

assert FR_013_NoRecordWithoutAudit { FR_013_NoRecordWithoutAudit }
check FR_013_NoRecordWithoutAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014; contracts/http-api.md fixed JSON key order, clinical-safety block
pred FR_014_AllergiesFirstInView {
  some RecordView
  all rv: RecordView {
    AllergiesSection  -> MedicationsSection in rv.sectionBefore
    AllergiesSection  -> EncountersSection  in rv.sectionBefore
    KeyWarningsSection -> MedicationsSection in rv.sectionBefore
    KeyWarningsSection -> EncountersSection  in rv.sectionBefore
  }
}

assert FR_014_AllergiesFirstInView { FR_014_AllergiesFirstInView }
check FR_014_AllergiesFirstInView for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015; contracts/http-api.md patient-verification block
pred FR_015_PatientIdDoBFirst {
  some RecordView
  all rv: RecordView {
    PatientIdSection   -> AllergiesSection   in rv.sectionBefore
    PatientIdSection   -> KeyWarningsSection  in rv.sectionBefore
    PatientIdSection   -> MedicationsSection  in rv.sectionBefore
    PatientIdSection   -> EncountersSection   in rv.sectionBefore
    DateOfBirthSection -> AllergiesSection   in rv.sectionBefore
    DateOfBirthSection -> KeyWarningsSection  in rv.sectionBefore
    DateOfBirthSection -> MedicationsSection  in rv.sectionBefore
    DateOfBirthSection -> EncountersSection   in rv.sectionBefore
  }
}

assert FR_015_PatientIdDoBFirst { FR_015_PatientIdDoBFirst }
check FR_015_PatientIdDoBFirst for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AppendOnlyViolation { some disj a1, a2: AccessAttempt | some a1.auditEntry and a1.auditEntry = a2.auditEntry }
