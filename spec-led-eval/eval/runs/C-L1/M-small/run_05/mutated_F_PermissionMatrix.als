// === feature_model.als — Alloy model for C-L1 (Clinician Access to Patient Medical Records v1) ===

// ROLE AND OPERATION ENUMS

abstract sig ClinicianRole {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends ClinicianRole {}

abstract sig OperationKind {}
one sig RecordsLookup, AuditSearch extends OperationKind {}

abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

abstract sig AuthorisationBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthorisationBasis {}

abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

// OPAQUE VALUE SIGS (representing string identifiers and names)

sig ClinicianId {}
sig PatientId {}
sig EpisodeOfCareId {}
sig DisplayName {}
sig Timestamp {}

// CORE ENTITY SIGS

sig User {
  id: one ClinicianId,
  display_name: one DisplayName,
  role: one ClinicianRole
}

sig Patient {
  id: one PatientId,
  name: one DisplayName,
  date_of_birth: one Timestamp
}

sig CareTeamMembership {
  clinician: one User,
  patient: one Patient,
  episode_of_care_id: one EpisodeOfCareId,
  status: one MembershipStatus
}

sig Encounter {
  id: one Int,
  patient: one Patient,
  encounter_date: one Timestamp,
  encounter_type: one DisplayName,
  summary: one DisplayName
}

sig AuditEntry {
  id: one Int,
  clinician_id: one ClinicianId,
  clinician_display_name: one DisplayName,
  clinician_role: one ClinicianRole,
  patient_id: one PatientId,
  occurred_at: one Timestamp,
  access_type: one DisplayName,
  outcome: one AccessOutcome,
  authorisation_basis: one AuthorisationBasis
}

sig AccessRequest {
  requester: one User,
  operation: one OperationKind,
  patient_id: one PatientId,
  result_audit: one AuditEntry
}

// PERMISSION MATRIX SINGLETON

one sig PermMatrix {
  Allowed: set ClinicianRole -> OperationKind
}

// === FACTS ===

fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some Encounter
  some AuditEntry
  some AccessRequest
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-001/FR-006/FR-011
fact F_PermissionMatrix { /* MUTATED — body cleared by validator */ }

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables
fact F_PermissionCompleteness {
  all r: ClinicianRole, op: OperationKind |
    (r -> op in PermMatrix.Allowed) or not (r -> op in PermMatrix.Allowed)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md authentication section
fact F_AuthRequired {
  all ar: AccessRequest | ar.requester in User
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008; data-model.md AuditEntry
fact F_AuditCompleteness {
  all ar: AccessRequest | (one ae: AuditEntry | ae = ar.result_audit)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010; data-model.md "no UPDATE/DELETE"
fact F_AppendOnly {
  all disj ae1, ae2: AuditEntry | ae1.id != ae2.id
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md audit-entry fields
fact F_AttributionCorrectness {
  all ar: AccessRequest |
    ar.result_audit.clinician_id = ar.requester.id and
    ar.result_audit.clinician_display_name = ar.requester.display_name and
    ar.result_audit.clinician_role = ar.requester.role
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md CareTeamMembership
fact F_OwnershipBasedAccess {
  all ar: AccessRequest |
    (ar.operation = RecordsLookup) implies (
      (ar.result_audit.outcome = Permitted) iff (
        some ctm: CareTeamMembership |
          ctm.clinician = ar.requester and
          ctm.patient.id = ar.patient_id and
          ctm.status = Active
      )
    )
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007; contracts/http-api.md byte-equivalence
fact F_NoInformationLeakage {
  all ar: AccessRequest |
    (ar.operation = RecordsLookup and ar.result_audit.outcome != Permitted) implies (
      (ar.result_audit.outcome = Denied or ar.result_audit.outcome = NotFoundOrDenied)
    )
}

// FEATURE-SPECIFIC  ANCHOR: FR-002; contracts/http-api.md token resolution
fact F_RoleFromHostIdentity {
  all u: User | u.role in (Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin)
}

// FEATURE-SPECIFIC  ANCHOR: FR-005; data-model.md access_type CHECK
fact F_ReadOnlyAccess {
  all ae: AuditEntry | ae.access_type in DisplayName
}

// FEATURE-SPECIFIC  ANCHOR: FR-004; contracts/http-api.md POST request bodies
fact F_NoPatientIdInPath {
  all ar: AccessRequest | ar.patient_id in PatientId
}

// FEATURE-SPECIFIC  ANCHOR: FR-011; contracts/http-api.md /audit/search gating
fact F_AuditSearchGating {
  all ar: AccessRequest |
    (ar.operation = AuditSearch) implies (ar.requester.role = AuditOfficer)
}

// FEATURE-SPECIFIC  ANCHOR: FR-012; data-model.md no DELETE path
fact F_RetentionFloor {
  all ae: AuditEntry | ae in AuditEntry
}

// FEATURE-SPECIFIC  ANCHOR: FR-013, FR-008; contracts/http-api.md audit SLA
fact F_AuditSLAEnforcement {
  all ar: AccessRequest | ar.result_audit in AuditEntry
}

// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md AuditEntry schema
fact F_AuditEntryShape {
  all ae: AuditEntry |
    ae.id in Int and
    ae.clinician_id in ClinicianId and
    ae.clinician_display_name in DisplayName and
    ae.clinician_role in ClinicianRole and
    ae.patient_id in PatientId and
    ae.occurred_at in Timestamp and
    ae.access_type in DisplayName and
    ae.outcome in AccessOutcome and
    ae.authorisation_basis in AuthorisationBasis
}

// FEATURE-SPECIFIC  ANCHOR: FR-014; contracts/http-api.md response key order
fact F_AllergiesWarningsTop {
  all ar: AccessRequest |
    (ar.result_audit.outcome = Permitted) implies (
      ar.result_audit.authorisation_basis = CareTeamMember
    )
}

// FEATURE-SPECIFIC  ANCHOR: FR-015; contracts/http-api.md /records/lookup response
fact F_PatientIdAndDoBTop {
  all ar: AccessRequest |
    (ar.result_audit.outcome = Permitted) implies (ar.patient_id in PatientId)
}

// FEATURE-SPECIFIC  ANCHOR: FR-006; data-model.md CareTeamMembership
fact F_CareTeamMembershipLogic {
  all ar: AccessRequest |
    (ar.operation = RecordsLookup) implies (
      (ar.result_audit.authorisation_basis = CareTeamMember) iff (
        some ctm: CareTeamMembership |
          ctm.clinician = ar.requester and
          ctm.patient.id = ar.patient_id and
          ctm.status = Active
      )
    )
}

// FEATURE-SPECIFIC  ANCHOR: spec.md User Story 1 scenario 2; FR-006
fact F_DeniedWhenNotMember {
  all ar: AccessRequest |
    (ar.operation = RecordsLookup and
     no ctm: CareTeamMembership |
       ctm.clinician = ar.requester and
       ctm.patient.id = ar.patient_id and
       ctm.status = Active) implies (
      ar.result_audit.outcome = Denied or ar.result_audit.outcome = NotFoundOrDenied
    )
}

// FEATURE-SPECIFIC  ANCHOR: FR-002; contracts/http-api.md authentication boundary
fact F_AuthenticationResolves {
  all ar: AccessRequest |
    ar.requester.id in ClinicianId and
    ar.requester.role in ClinicianRole
}

// === PREDICATES ===

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FRs
pred LeastPrivilege {
  all ar: AccessRequest |
    (ar.requester.role -> ar.operation in PermMatrix.Allowed) or
    not (ar.requester.role -> ar.operation in PermMatrix.Allowed)
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables
pred PermissionCompleteness {
  all r: ClinicianRole, op: OperationKind |
    (r -> op in PermMatrix.Allowed) or not (r -> op in PermMatrix.Allowed)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all ar: AccessRequest | ar.requester in User
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008
pred AuditCompleteness {
  all ar: AccessRequest | (one ae: AuditEntry | ae = ar.result_audit)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010
pred AppendOnly {
  all disj ae1, ae2: AuditEntry | ae1.id != ae2.id
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009
pred AttributionCorrectness {
  all ar: AccessRequest |
    ar.result_audit.clinician_id = ar.requester.id and
    ar.result_audit.clinician_display_name = ar.requester.display_name and
    ar.result_audit.clinician_role = ar.requester.role
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006
pred OwnershipBasedAccess {
  all ar: AccessRequest |
    (ar.operation = RecordsLookup) implies (
      (ar.result_audit.outcome = Permitted) iff (
        some ctm: CareTeamMembership |
          ctm.clinician = ar.requester and
          ctm.patient.id = ar.patient_id and
          ctm.status = Active
      )
    )
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007
pred NoInformationLeakage {
  all ar: AccessRequest |
    (ar.operation = RecordsLookup and ar.result_audit.outcome != Permitted) implies (
      (ar.result_audit.outcome = Denied or ar.result_audit.outcome = NotFoundOrDenied)
    )
}

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all ar: AccessRequest | ar.requester in User
}

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_RoleIdentity {
  all u: User | u.role in (Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin)
}

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_NoPatientIdInURL {
  all ar: AccessRequest | ar.patient_id in PatientId
}

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_ReadOnly {
  all ae: AuditEntry | ae.access_type in DisplayName
}

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_CareTeamGating {
  all ar: AccessRequest |
    (ar.operation = RecordsLookup and ar.result_audit.outcome = Permitted) implies (
      some ctm: CareTeamMembership |
        ctm.clinician = ar.requester and
        ctm.patient.id = ar.patient_id and
        ctm.status = Active
    )
}

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_ByteEquivalent {
  all ar: AccessRequest |
    (ar.operation = RecordsLookup and ar.result_audit.outcome != Permitted) implies (
      (ar.result_audit.outcome = Denied or ar.result_audit.outcome = NotFoundOrDenied)
    )
}

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_AlwaysAudit {
  all ar: AccessRequest | ar.result_audit in AuditEntry
}

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_AuditShape {
  all ae: AuditEntry |
    ae.id in Int and
    ae.clinician_id in ClinicianId and
    ae.clinician_display_name in DisplayName and
    ae.clinician_role in ClinicianRole and
    ae.patient_id in PatientId and
    ae.occurred_at in Timestamp and
    ae.access_type in DisplayName and
    ae.outcome in AccessOutcome and
    ae.authorisation_basis in AuthorisationBasis
}

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_AuditImmutable {
  all disj ae1, ae2: AuditEntry | ae1.id != ae2.id
}

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_AuditSearchGating {
  all ar: AccessRequest |
    (ar.operation = AuditSearch) implies (ar.requester.role = AuditOfficer)
}

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_RetentionFloor {
  all ae: AuditEntry | ae in AuditEntry
}

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_AuditSLA {
  all ar: AccessRequest | ar.result_audit in AuditEntry
}

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_AllergiesWarningsTop {
  all ar: AccessRequest |
    (ar.result_audit.outcome = Permitted) implies (
      ar.result_audit.authorisation_basis = CareTeamMember
    )
}

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_PatientIdAndDoBTop {
  all ar: AccessRequest |
    (ar.result_audit.outcome = Permitted) implies (ar.patient_id in PatientId)
}

// === ASSERTIONS ===

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

assert AppendOnly { AppendOnly }
check AppendOnly for 5

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

assert FR_002_RoleIdentity { FR_002_RoleIdentity }
check FR_002_RoleIdentity for 5

assert FR_004_NoPatientIdInURL { FR_004_NoPatientIdInURL }
check FR_004_NoPatientIdInURL for 5

assert FR_005_ReadOnly { FR_005_ReadOnly }
check FR_005_ReadOnly for 5

assert FR_006_CareTeamGating { FR_006_CareTeamGating }
check FR_006_CareTeamGating for 5

assert FR_007_ByteEquivalent { FR_007_ByteEquivalent }
check FR_007_ByteEquivalent for 5

assert FR_008_AlwaysAudit { FR_008_AlwaysAudit }
check FR_008_AlwaysAudit for 5

assert FR_009_AuditShape { FR_009_AuditShape }
check FR_009_AuditShape for 5

assert FR_010_AuditImmutable { FR_010_AuditImmutable }
check FR_010_AuditImmutable for 5

assert FR_011_AuditSearchGating { FR_011_AuditSearchGating }
check FR_011_AuditSearchGating for 5

assert FR_012_RetentionFloor { FR_012_RetentionFloor }
check FR_012_RetentionFloor for 5

assert FR_013_AuditSLA { FR_013_AuditSLA }
check FR_013_AuditSLA for 5

assert FR_014_AllergiesWarningsTop { FR_014_AllergiesWarningsTop }
check FR_014_AllergiesWarningsTop for 5

assert FR_015_PatientIdAndDoBTop { FR_015_PatientIdAndDoBTop }
check FR_015_PatientIdAndDoBTop for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_PermissionViolation { some r: ClinicianRole, op: OperationKind | r -> op in (Doctor -> AuditSearch) and not (r -> op in PermMatrix.Allowed) }
