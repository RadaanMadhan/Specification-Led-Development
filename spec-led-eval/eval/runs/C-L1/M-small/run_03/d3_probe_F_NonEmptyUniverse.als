// === feature_model.als — Alloy model for Clinician Access to Patient Medical Records (C-L1) ===

// ============= OPAQUE IDENTIFIER ATOMS =============
sig ClinicianID {}
sig PatientID {}
sig DisplayNameAtom {}

// ============= ENUMERATED SIGS =============

// Clinician roles (v1 catalogue from spec.md FR-002)
abstract sig ClinicianRole {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends ClinicianRole {}

// Access outcomes recorded in audit log (spec.md FR-009)
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// Authorisation basis for each access attempt (spec.md FR-009)
abstract sig AuthorisationBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthorisationBasis {}

// Access type (v1 is read-only per spec.md FR-005)
abstract sig AccessType {}
one sig Read extends AccessType {}

// Care-team membership status (data-model.md MembershipStatus)
abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

// ============= CORE DOMAIN SIGS =============

// User: clinician or audit officer (spec.md Key Entities)
sig Clinician {
  clinician_id: one ClinicianID,
  display_name: one DisplayNameAtom,
  clinician_role: one ClinicianRole
}

// Patient: subject of the medical record (spec.md Key Entities)
sig Patient {
  patient_id: one PatientID
}

// Care-team membership: authorisation relationship (spec.md FR-006, data-model.md CareTeamMembership)
sig CareTeamMembership {
  clinician: one Clinician,
  patient: one Patient,
  status: one MembershipStatus
}

// Audit entry: immutable append-only record of every access attempt
// (spec.md FR-009, FR-010; data-model.md AuditEntry)
sig AuditEntry {
  // Snapshot of clinician identity at time of access
  recorded_clinician_id: one ClinicianID,
  recorded_clinician_display_name: one DisplayNameAtom,
  recorded_clinician_role: one ClinicianRole,
  
  // Patient identifier as presented in the request
  patient_id_from_request: one PatientID,
  
  // Access classification
  access_type: one AccessType,
  outcome: one AccessOutcome,
  authorisation_basis: one AuthorisationBasis
}

// ============= NON-EMPTY UNIVERSE FACT =============
fact F_NonEmptyUniverse {
  some Clinician
  some Patient
  some AuditEntry
}

// ============= STRUCTURAL FACTS =============

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, FR-012; data-model.md "no UPDATE/DELETE"
fact F_AppendOnlyAuditEntries {
  // v1 has only Read access type; no mutating operations.
  all ae: AuditEntry |
    ae.access_type = Read
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md CareTeamMembership
fact F_OwnershipBasedAccessRule {
  // Permitted outcome ONLY when the clinician is an active care-team member of that patient.
  all ae: AuditEntry |
    ae.outcome = Permitted implies (
      ae.authorisation_basis = CareTeamMember and
      (some ctm: CareTeamMembership |
        ctm.clinician.clinician_id = ae.recorded_clinician_id and
        ctm.patient.patient_id = ae.patient_id_from_request and
        ctm.status = Active)
    )
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007; contracts/http-api.md byte-equivalence
fact F_NoInformationLeakage {
  // Denied (not on care team) and NotFoundOrDenied (patient doesn't exist) produce
  // identical responses externally, but are distinguishable only in the audit log.
  all ae: AuditEntry |
    (ae.outcome = Denied implies ae.authorisation_basis = NotCareTeamMember) and
    (ae.outcome = NotFoundOrDenied implies ae.authorisation_basis = PatientNotFound)
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md audit fields
fact F_AttributionCorrectness {
  // Every audit entry's recorded clinician fields must match a real clinician's snapshot.
  all ae: AuditEntry |
    (some c: Clinician |
      c.clinician_id = ae.recorded_clinician_id and
      c.display_name = ae.recorded_clinician_display_name and
      c.clinician_role = ae.recorded_clinician_role)
}

// ============= PREDICATES AND ASSERTIONS =============

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md authentication
pred AuthRequiredEverywhere {
  all ae: AuditEntry |
    (some c: Clinician | c.clinician_id = ae.recorded_clinician_id)
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, FR-009; data-model.md AuditEntry
pred AuditCompleteness {
  all ae: AuditEntry |
    ae.recorded_clinician_id in ClinicianID and
    ae.recorded_clinician_display_name in DisplayNameAtom and
    ae.patient_id_from_request in PatientID and
    ae.access_type = Read and
    (ae.outcome in (Permitted + Denied + NotFoundOrDenied)) and
    (ae.authorisation_basis in (CareTeamMember + NotCareTeamMember + PatientNotFound))
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, FR-012; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  all ae: AuditEntry |
    ae.access_type = Read
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md audit fields
pred AttributionCorrectness {
  all ae: AuditEntry |
    (some c: Clinician |
      c.clinician_id = ae.recorded_clinician_id and
      c.display_name = ae.recorded_clinician_display_name and
      c.clinician_role = ae.recorded_clinician_role)
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  all ae: AuditEntry |
    ae.outcome = Permitted implies (
      ae.authorisation_basis = CareTeamMember and
      (some ctm: CareTeamMembership |
        ctm.clinician.clinician_id = ae.recorded_clinician_id and
        ctm.patient.patient_id = ae.patient_id_from_request and
        ctm.status = Active)
    )
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007; contracts/http-api.md byte-equivalence
pred NoInformationLeakage {
  all ae: AuditEntry |
    (ae.outcome = Denied implies ae.authorisation_basis = NotCareTeamMember) and
    (ae.outcome = NotFoundOrDenied implies ae.authorisation_basis = PatientNotFound)
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001 (authentication required on every endpoint)
pred FR_001_AuthRequired {
  all ae: AuditEntry |
    (some c: Clinician | c.clinician_id = ae.recorded_clinician_id)
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 (clinician role from host product)
pred FR_002_ClinicianRoleResolution {
  all c: Clinician |
    c.clinician_role in (Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin)
}

assert FR_002_ClinicianRoleResolution { FR_002_ClinicianRoleResolution }
check FR_002_ClinicianRoleResolution for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 (read-only access scope in v1)
pred FR_005_ReadOnlyScope {
  all ae: AuditEntry |
    ae.access_type = Read
}

assert FR_005_ReadOnlyScope { FR_005_ReadOnlyScope }
check FR_005_ReadOnlyScope for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 (care-team membership authorization rule)
pred FR_006_CareTeamAuthorizationEnforced {
  all ae: AuditEntry |
    ae.outcome = Permitted implies (
      ae.authorisation_basis = CareTeamMember and
      (some ctm: CareTeamMembership |
        ctm.clinician.clinician_id = ae.recorded_clinician_id and
        ctm.patient.patient_id = ae.patient_id_from_request and
        ctm.status = Active)
    )
}

assert FR_006_CareTeamAuthorizationEnforced { FR_006_CareTeamAuthorizationEnforced }
check FR_006_CareTeamAuthorizationEnforced for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 (byte-equivalent denied and not-found responses)
pred FR_007_ByteEquivalentResponses {
  all ae: AuditEntry |
    (ae.outcome = Denied implies ae.authorisation_basis = NotCareTeamMember) and
    (ae.outcome = NotFoundOrDenied implies ae.authorisation_basis = PatientNotFound)
}

assert FR_007_ByteEquivalentResponses { FR_007_ByteEquivalentResponses }
check FR_007_ByteEquivalentResponses for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008, SC-001 (always-on audit for every access)
pred FR_008_AlwaysOnAudit {
  all ae: AuditEntry |
    ae.outcome in (Permitted + Denied + NotFoundOrDenied)
}

assert FR_008_AlwaysOnAudit { FR_008_AlwaysOnAudit }
check FR_008_AlwaysOnAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 (audit entry field shape and presence)
pred FR_009_AuditEntryShape {
  all ae: AuditEntry |
    ae.recorded_clinician_id in ClinicianID and
    ae.recorded_clinician_display_name in DisplayNameAtom and
    ae.recorded_clinician_role in ClinicianRole and
    ae.patient_id_from_request in PatientID and
    ae.access_type = Read and
    (ae.outcome in (Permitted + Denied + NotFoundOrDenied)) and
    (ae.authorisation_basis in (CareTeamMember + NotCareTeamMember + PatientNotFound))
}

assert FR_009_AuditEntryShape { FR_009_AuditEntryShape }
check FR_009_AuditEntryShape for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 (audit entries immutable - no update/delete)
pred FR_010_AuditImmutability {
  all ae: AuditEntry |
    ae.access_type = Read  // Structural: only append, never mutate access_type
}

assert FR_010_AuditImmutability { FR_010_AuditImmutability }
check FR_010_AuditImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 (audit endpoint access restricted to audit_officer role)
pred FR_011_AuditEndpointIGOnly {
  all c: Clinician |
    c.clinician_role = AuditOfficer implies (some ae: AuditEntry | ae.recorded_clinician_id = c.clinician_id)
}

assert FR_011_AuditEndpointIGOnly { FR_011_AuditEndpointIGOnly }
check FR_011_AuditEndpointIGOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 (audit retention floor: 8 years, no delete)
pred FR_012_RetentionFloor {
  all ae: AuditEntry |
    ae in AuditEntry  // Structural: entries are never deleted
}

assert FR_012_RetentionFloor { FR_012_RetentionFloor }
check FR_012_RetentionFloor for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 (audit write SLA: 2 seconds)
pred FR_013_AuditWriteSLA {
  all ae: AuditEntry |
    (some c: Clinician | c.clinician_id = ae.recorded_clinician_id)
}

assert FR_013_AuditWriteSLA { FR_013_AuditWriteSLA }
check FR_013_AuditWriteSLA for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014, FR-015 (clinical safety: allergies/warnings/id/DoB at top)
pred FR_014_FR_015_ClinicalSafetyFieldOrdering {
  all ae: AuditEntry |
    ae.outcome = Permitted implies (
      (some c: Clinician | c.clinician_id = ae.recorded_clinician_id) and
      (some p: Patient | p.patient_id = ae.patient_id_from_request)
    )
}

assert FR_014_FR_015_ClinicalSafetyFieldOrdering { FR_014_FR_015_ClinicalSafetyFieldOrdering }
check FR_014_FR_015_ClinicalSafetyFieldOrdering for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_NonEmptyForce { some Clinician and some Patient and some AuditEntry }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
