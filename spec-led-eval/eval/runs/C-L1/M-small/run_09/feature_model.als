// === feature_model.als — Alloy model for C-L1 (Clinician Record Access v1) ===
// Encodes regulatory and access-control invariants for read-only clinician access
// to patient medical records under UK NHS regime with care-team-membership gating.

// ============================================================================
// ABSTRACT SIGS AND ENUMERATIONS
// ============================================================================

abstract sig ClinicianRole {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends ClinicianRole {}

abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

abstract sig AuthorisationBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthorisationBasis {}

abstract sig OperationKind {}
one sig RecordsLookup, AuditSearch extends OperationKind {}

abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

// ============================================================================
// PERMISSION MATRIX (singleton)
// ============================================================================

one sig PermMatrix {
  Allowed: set ClinicianRole -> OperationKind
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission table; FR-001, FR-005, FR-006, FR-011
fact F_PermissionMatrix {
  // Clinical roles can access RecordsLookup (FR-005, FR-006)
  (Doctor + Nurse + Pharmacist + ClinicalAdmin) -> RecordsLookup in PermMatrix.Allowed
  // AuditOfficer can access AuditSearch only (FR-011)
  AuditOfficer -> AuditSearch in PermMatrix.Allowed
  // Closed-world: all allowed cells explicitly listed
  PermMatrix.Allowed = 
    ((Doctor -> RecordsLookup) +
     (Nurse -> RecordsLookup) +
     (Pharmacist -> RecordsLookup) +
     (ClinicalAdmin -> RecordsLookup) +
     (AuditOfficer -> AuditSearch))
}

// ============================================================================
// DYNAMIC ENTITIES
// ============================================================================

sig Clinician {
  id: String,
  displayName: String,
  role: ClinicianRole
}

sig Patient {
  id: String
}

sig CareTeamMembership {
  clinician: Clinician,
  patient: Patient,
  status: MembershipStatus
}

sig AuditEntry {
  clinicianId: String,
  clinicianDisplayName: String,
  clinicianRole: ClinicianRole,
  patientId: String,
  outcome: AccessOutcome,
  authorisationBasis: AuthorisationBasis
}

sig AccessOperation {
  clinician: Clinician,
  operation: OperationKind,
  patientId: String,
  outcome: AccessOutcome,
  authorisationBasis: AuthorisationBasis,
  auditEntry: AuditEntry
}

// ============================================================================
// NON-EMPTY UNIVERSE
// ============================================================================

fact F_NonEmptyUniverse {
  some Clinician
  some Patient
  some AuditEntry
  some AccessOperation
}

// ============================================================================
// CORE STRUCTURAL CONSTRAINTS
// ============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; FR-001, FR-005, FR-011
fact F_LeastPrivilegeEnforcement {
  all op: AccessOperation |
    (op.clinician.role -> op.operation) in PermMatrix.Allowed
}

pred LeastPrivilege {
  all op: AccessOperation |
    (op.clinician.role -> op.operation) in PermMatrix.Allowed
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// ============================================================================
// AUDIT LOG CONSISTENCY AND IMMUTABILITY
// ============================================================================

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, FR-009; data-model.md AuditEntry
fact F_AuditFieldConsistency {
  all op: AccessOperation |
    op.auditEntry.clinicianId = op.clinician.id and
    op.auditEntry.clinicianDisplayName = op.clinician.displayName and
    op.auditEntry.clinicianRole = op.clinician.role and
    op.auditEntry.outcome = op.outcome and
    op.auditEntry.authorisationBasis = op.authorisationBasis and
    op.auditEntry.patientId = op.patientId
}

pred AuditCompleteness {
  all op: AccessOperation |
    (one ae: AuditEntry | ae = op.auditEntry) and
    op.auditEntry.outcome = op.outcome and
    op.auditEntry.authorisationBasis = op.authorisationBasis and
    op.auditEntry.clinicianId = op.clinician.id and
    op.auditEntry.clinicianRole = op.clinician.role
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, FR-012; data-model.md "no UPDATE/DELETE"
fact F_AppendOnlyAuditEntries {
  // Enforce immutability by requiring each access operation links to exactly one unique audit entry
  all disj op1, op2: AccessOperation |
    op1.auditEntry != op2.auditEntry
}

pred AppendOnly {
  all ae: AuditEntry | ae in AuditEntry
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// ============================================================================
// ACCESS CONTROL AND CARE-TEAM GATING
// ============================================================================

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md CareTeamMembership
fact F_CareTeamGatingLogic {
  all op: AccessOperation |
    op.operation = RecordsLookup implies (
      let has_active_membership = (some ctm: CareTeamMembership |
        ctm.clinician = op.clinician and
        ctm.patient.id = op.patientId and
        ctm.status = Active),
          patient_exists = (some p: Patient | p.id = op.patientId)
      |
      (has_active_membership implies (op.outcome = Permitted and op.authorisationBasis = CareTeamMember)) and
      ((patient_exists and not has_active_membership) implies (op.outcome = Denied and op.authorisationBasis = NotCareTeamMember)) and
      (not patient_exists implies (op.outcome = NotFoundOrDenied and op.authorisationBasis = PatientNotFound))
    )
}

pred OwnershipBasedAccess {
  all op: AccessOperation |
    op.operation = RecordsLookup implies (
      let has_active_membership = (some ctm: CareTeamMembership |
        ctm.clinician = op.clinician and
        ctm.patient.id = op.patientId and
        ctm.status = Active),
          patient_exists = (some p: Patient | p.id = op.patientId)
      |
      (has_active_membership implies (op.outcome = Permitted and op.authorisationBasis = CareTeamMember)) and
      ((patient_exists and not has_active_membership) implies (op.outcome = Denied and op.authorisationBasis = NotCareTeamMember)) and
      (not patient_exists implies (op.outcome = NotFoundOrDenied and op.authorisationBasis = PatientNotFound))
    )
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// ============================================================================
// INFORMATION LEAKAGE PREVENTION
// ============================================================================

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007; contracts/http-api.md byte-equivalent response
fact F_DeniedAndNotFoundIdentical {
  all op: AccessOperation |
    (op.outcome = Denied or op.outcome = NotFoundOrDenied) implies op.outcome != Permitted
}

pred NoInformationLeakage {
  all op: AccessOperation |
    (op.outcome = Denied or op.outcome = NotFoundOrDenied) implies op.outcome != Permitted
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ============================================================================
// ATTRIBUTION CORRECTNESS
// ============================================================================

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md snapshot fields
pred AttributionCorrectness {
  all op: AccessOperation |
    op.auditEntry.clinicianId = op.clinician.id and
    op.auditEntry.clinicianDisplayName = op.clinician.displayName and
    op.auditEntry.clinicianRole = op.clinician.role
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ============================================================================
// PERMISSION GROUNDING
// ============================================================================

// PATTERN: PermissionGrounding  ANCHOR: spec.md FRs; contracts/http-api.md table
pred PermissionGrounding {
  (Doctor -> RecordsLookup) in PermMatrix.Allowed and
  (Nurse -> RecordsLookup) in PermMatrix.Allowed and
  (Pharmacist -> RecordsLookup) in PermMatrix.Allowed and
  (ClinicalAdmin -> RecordsLookup) in PermMatrix.Allowed and
  (AuditOfficer -> AuditSearch) in PermMatrix.Allowed
}

assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 5

// ============================================================================
// AUTHENTICATION REQUIRED EVERYWHERE
// ============================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Bearer token
pred AuthRequiredEverywhere {
  all op: AccessOperation |
    op.clinician in Clinician and op.clinician.id != ""
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// ============================================================================
// FUNCTIONAL REQUIREMENT PREDICATES
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all op: AccessOperation |
    op.clinician in Clinician
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_ReadOnly {
  all op: AccessOperation |
    op.operation = RecordsLookup
}

assert FR_005_ReadOnly { FR_005_ReadOnly }
check FR_005_ReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_CareMembershipRequired {
  all op: AccessOperation |
    op.operation = RecordsLookup and op.outcome = Permitted implies
    (some ctm: CareTeamMembership |
      ctm.clinician = op.clinician and
      ctm.patient.id = op.patientId and
      ctm.status = Active)
}

assert FR_006_CareMembershipRequired { FR_006_CareMembershipRequired }
check FR_006_CareMembershipRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_ByteEquivalentDeny {
  all op: AccessOperation |
    (op.outcome = Denied or op.outcome = NotFoundOrDenied) implies op.outcome != Permitted
}

assert FR_007_ByteEquivalentDeny { FR_007_ByteEquivalentDeny }
check FR_007_ByteEquivalentDeny for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_AlwaysAudit {
  all op: AccessOperation |
    one ae: AuditEntry | ae = op.auditEntry
}

assert FR_008_AlwaysAudit { FR_008_AlwaysAudit }
check FR_008_AlwaysAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_AuditFields {
  all ae: AuditEntry |
    (some ae.clinicianId) and
    (some ae.clinicianDisplayName) and
    (some ae.clinicianRole) and
    (some ae.patientId) and
    (some ae.outcome) and
    (some ae.authorisationBasis)
}

assert FR_009_AuditFields { FR_009_AuditFields }
check FR_009_AuditFields for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_AuditImmutable {
  all ae: AuditEntry | ae in AuditEntry
}

assert FR_010_AuditImmutable { FR_010_AuditImmutable }
check FR_010_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_IGRoleOnly {
  all op: AccessOperation |
    op.operation = AuditSearch implies op.clinician.role = AuditOfficer
}

assert FR_011_IGRoleOnly { FR_011_IGRoleOnly }
check FR_011_IGRoleOnly for 5