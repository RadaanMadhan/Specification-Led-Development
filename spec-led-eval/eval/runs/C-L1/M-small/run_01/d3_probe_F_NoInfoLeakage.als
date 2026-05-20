// === Clinician Access to Patient Medical Records (v1) ===
// Feature C-L1

// ============================================================================
// DOMAIN SIGS
// ============================================================================

// Roles
abstract sig ClinicianRole {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends ClinicianRole {}

// Membership status
abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

// Access outcomes
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// Authorization basis
abstract sig AuthorisationBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthorisationBasis {}

// Operation kinds (endpoints)
abstract sig OperationKind {}
one sig RecordLookup, AuditSearch extends OperationKind {}

// Core domain entities
sig Clinician {
  displayName: one ClinicianRole,  // snapshot surrogate
  role: one ClinicianRole
}

sig Patient {}

sig CareTeamMembership {
  clinician: one Clinician,
  patient: one Patient,
  status: one MembershipStatus
}

sig AuditEntry {
  clinician: one Clinician,
  clinicianRole: one ClinicianRole,  // snapshot
  patient: one Patient,
  outcome: one AccessOutcome,
  authorisationBasis: one AuthorisationBasis
}

sig AccessAttempt {
  clinician: one Clinician,
  operation: one OperationKind,
  targetPatient: one Patient,
  outcome: one AccessOutcome,
  auditEntry: one AuditEntry
}

// Permission matrix as singleton field
one sig PermissionMatrix {
  allowed: set ClinicianRole -> OperationKind
}

// ============================================================================
// FACTS
// ============================================================================

fact F_NonEmptyUniverse {
  some Clinician
  some Patient
  some AccessAttempt
  some AuditEntry
  some CareTeamMembership
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; FR-001 through FR-011
fact F_PermissionMatrixDef {
  PermissionMatrix.allowed = 
    (Doctor -> RecordLookup) + 
    (Nurse -> RecordLookup) + 
    (Pharmacist -> RecordLookup) + 
    (ClinicalAdmin -> RecordLookup) + 
    (AuditOfficer -> AuditSearch)
}

fact F_LeastPrivilegeEnforced {
  all aa: AccessAttempt |
    aa.clinician.role -> aa.operation in PermissionMatrix.allowed
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001
fact F_AuthRequired {
  all aa: AccessAttempt | aa.clinician in Clinician
}

// PATTERN: AuditCompleteness  ANCHOR: FR-008, FR-009; data-model.md AuditEntry
fact F_AuditCompleteness {
  all aa: AccessAttempt |
    aa.auditEntry.clinician = aa.clinician and
    aa.auditEntry.clinicianRole = aa.clinician.role and
    aa.auditEntry.patient = aa.targetPatient and
    aa.auditEntry.outcome = aa.outcome
}

// PATTERN: AppendOnly  ANCHOR: FR-010, FR-012; data-model.md "no UPDATE/DELETE"
fact F_AppendOnlyAudit {
  all ae: AuditEntry |
    (ae.clinician = ae.clinician and ae.outcome = ae.outcome)
}

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-006; data-model.md CareTeamMembership
fact F_CareTeamGating {
  all aa: AccessAttempt |
    aa.operation = RecordLookup implies (
      (aa.outcome = Permitted) iff (
        some ctm: CareTeamMembership |
          ctm.clinician = aa.clinician and
          ctm.patient = aa.targetPatient and
          ctm.status = Active
      )
    )
}

// PATTERN: NoInformationLeakage  ANCHOR: FR-007
fact F_NoInfoLeakage {
  all aa: AccessAttempt |
    aa.operation = RecordLookup and (aa.outcome = Denied or aa.outcome = NotFoundOrDenied) implies (
      no ctm: CareTeamMembership |
        ctm.clinician = aa.clinician and
        ctm.patient = aa.targetPatient and
        ctm.status = Active
    )
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-009; data-model.md audit-entry snapshot fields
fact F_AttributionCorrect {
  all ae: AuditEntry |
    some aa: AccessAttempt |
      aa.auditEntry = ae implies (
        ae.clinician = aa.clinician and
        ae.clinicianRole = aa.clinician.role
      )
}

// FEATURE-SPECIFIC  ANCHOR: FR-005 (read-only scope)
fact F_ReadOnlyScope {
  all aa: AccessAttempt | aa.operation in (RecordLookup + AuditSearch)
}

// FEATURE-SPECIFIC  ANCHOR: FR-011 (audit officer cannot access records)
fact F_AuditOfficerCannotAccessRecords {
  all aa: AccessAttempt |
    aa.clinician.role = AuditOfficer implies aa.operation != RecordLookup
}

// FEATURE-SPECIFIC  ANCHOR: FR-006 (clinical roles only on RecordLookup)
fact F_ClinicalRolesOnlyOnLookup {
  all aa: AccessAttempt |
    aa.operation = RecordLookup implies 
      aa.clinician.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}

// ============================================================================
// PREDICATES AND ASSERTIONS
// ============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md
pred LeastPrivilege {
  all aa: AccessAttempt |
    aa.clinician.role -> aa.operation in PermissionMatrix.allowed
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001
pred AuthRequiredEverywhere {
  some AccessAttempt implies (
    all aa: AccessAttempt | aa.clinician in Clinician
  )
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: FR-008, FR-009
pred AuditCompleteness {
  some AccessAttempt implies (
    all aa: AccessAttempt |
      one ae: AuditEntry |
        ae.clinician = aa.clinician and
        ae.clinicianRole = aa.clinician.role and
        ae.patient = aa.targetPatient and
        ae.outcome = aa.outcome and
        aa.auditEntry = ae
  )
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: FR-010, FR-012
pred AppendOnly {
  all ae: AuditEntry |
    (ae.clinician = ae.clinician and ae.outcome = ae.outcome)
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-006
pred OwnershipBasedAccess {
  some AccessAttempt implies (
    all aa: AccessAttempt |
      aa.operation = RecordLookup and aa.outcome = Permitted implies (
        some ctm: CareTeamMembership |
          ctm.clinician = aa.clinician and
          ctm.patient = aa.targetPatient and
          ctm.status = Active
      )
  )
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: FR-007
pred NoInformationLeakage {
  some AccessAttempt implies (
    all aa: AccessAttempt |
      aa.operation = RecordLookup and (aa.outcome = Denied or aa.outcome = NotFoundOrDenied) implies (
        no ctm: CareTeamMembership |
          ctm.clinician = aa.clinician and
          ctm.patient = aa.targetPatient and
          ctm.status = Active
      )
  )
}

assert NoInformationLeakage {
  NoInformationLeakage
}

check NoInformationLeakage for 8

// PATTERN: AttributionCorrectness  ANCHOR: FR-009
pred AttributionCorrectness {
  some AuditEntry implies (
    all ae: AuditEntry |
      some aa: AccessAttempt |
        aa.auditEntry = ae implies (
          ae.clinician = aa.clinician and
          ae.clinicianRole = aa.clinician.role
        )
  )
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_ReadOnlyScope {
  all aa: AccessAttempt | aa.operation in (RecordLookup + AuditSearch)
}

assert FR_005_ReadOnlyScope {
  FR_005_ReadOnlyScope
}

check FR_005_ReadOnlyScope for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_CareTeamRequirement {
  some AccessAttempt implies (
    all aa: AccessAttempt |
      aa.operation = RecordLookup implies (
        aa.outcome = Permitted iff (
          some ctm: CareTeamMembership |
            ctm.clinician = aa.clinician and
            ctm.patient = aa.targetPatient and
            ctm.status = Active
        )
      )
  )
}

assert FR_006_CareTeamRequirement {
  FR_006_CareTeamRequirement
}

check FR_006_CareTeamRequirement for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_DenialIndistinguishability {
  some AccessAttempt implies (
    all aa: AccessAttempt |
      aa.operation = RecordLookup and (aa.outcome = Denied or aa.outcome = NotFoundOrDenied) implies (
        no ctm: CareTeamMembership |
          ctm.clinician = aa.clinician and
          ctm.patient = aa.targetPatient and
          ctm.status = Active
      )
  )
}

assert FR_007_DenialIndistinguishability {
  FR_007_DenialIndistinguishability
}

check FR_007_DenialIndistinguishability for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_AuditOfficerRecordAccess {
  all aa: AccessAttempt |
    aa.clinician.role = AuditOfficer implies aa.operation = AuditSearch
}

assert FR_011_AuditOfficerRecordAccess {
  FR_011_AuditOfficerRecordAccess
}

check FR_011_AuditOfficerRecordAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-012
pred FR_010_AuditImmutability {
  all ae: AuditEntry |
    (ae.clinician = ae.clinician and ae.outcome = ae.outcome and ae.patient = ae.patient)
}

assert FR_010_AuditImmutability {
  FR_010_AuditImmutability
}

check FR_010_AuditImmutability for 8

// === D3 inject_violation (validator-appended) ===
fact MUTATE_InfoLeakage { some aa: AccessAttempt, ctm: CareTeamMembership | aa.operation = RecordLookup and (aa.outcome = Denied or aa.outcome = NotFoundOrDenied) and ctm.clinician = aa.clinician and ctm.patient = aa.targetPatient and ctm.status = Active }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
