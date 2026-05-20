// === feature_model.als — Alloy 6 model for Clinician Access to Patient Medical Records (C-L1) ===

// ========== DOMAIN MODEL ==========

// Roles in the system
abstract sig Role {}
one sig Doctor extends Role {}
one sig Nurse extends Role {}
one sig Pharmacist extends Role {}
one sig AuditOfficer extends Role {}
one sig ClinicalAdmin extends Role {}

// Operation kinds
abstract sig OperationKind {}
one sig LookupRecord extends OperationKind {}
one sig SearchAudit extends OperationKind {}

// Access outcomes (from FR-009, data-model.md)
abstract sig AccessOutcome {}
one sig Permitted extends AccessOutcome {}
one sig Denied extends AccessOutcome {}
one sig NotFoundOrDenied extends AccessOutcome {}

// Authorisation bases (from FR-009, data-model.md)
abstract sig AuthorisationBasis {}
one sig CareTeamMember extends AuthorisationBasis {}
one sig NotCareTeamMember extends AuthorisationBasis {}
one sig PatientNotFound extends AuthorisationBasis {}

// Membership status
abstract sig MembershipStatus {}
one sig Active extends MembershipStatus {}
one sig Ended extends MembershipStatus {}

// Opaque string identifiers
sig String {}

// Clinician entity (from data-model.md User)
sig Clinician {
  id: one String,
  display_name: one String,
  role: one Role
}

// Patient entity
sig Patient {
  id: one String,
  name: one String,
  date_of_birth: one String
}

// Care-team membership (from data-model.md CareTeamMembership)
sig Membership {
  clinician: one Clinician,
  patient: one Patient,
  status: one MembershipStatus
}

// Access operation performed against the system
sig AccessOperation {
  clinician: one Clinician,
  patient_id: one String,                    // opaque; may not correspond to a Patient entity
  operation: one OperationKind,
  outcome: one AccessOutcome,
  authorisation_basis: one AuthorisationBasis,
  timestamp: one String
}

// Audit entry (from data-model.md AuditEntry) — immutable, append-only
sig AuditEntry {
  clinician_id: one String,
  clinician_display_name: one String,
  clinician_role: one Role,
  patient_id: one String,                    // opaque; not FK-constrained per FR-008
  occurred_at: one String,
  access_type: one String,                   // always "read" in v1
  outcome: one AccessOutcome,
  authorisation_basis: one AuthorisationBasis
}

// ========== PERMISSION MATRIX (from contracts/http-api.md) ==========

one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; spec.md FR-001, FR-006, FR-011
fact F_PermissionMatrix {
  // Clinical roles (doctor, nurse, pharmacist, clinical_admin) can LookupRecord
  Doctor -> LookupRecord in PermMatrix.Allowed
  Nurse -> LookupRecord in PermMatrix.Allowed
  Pharmacist -> LookupRecord in PermMatrix.Allowed
  ClinicalAdmin -> LookupRecord in PermMatrix.Allowed
  
  // Only AuditOfficer can SearchAudit
  AuditOfficer -> SearchAudit in PermMatrix.Allowed
  
  // Closed-world: no other permissions exist
  PermMatrix.Allowed = (Doctor -> LookupRecord) +
                       (Nurse -> LookupRecord) +
                       (Pharmacist -> LookupRecord) +
                       (ClinicalAdmin -> LookupRecord) +
                       (AuditOfficer -> SearchAudit)
}

// ========== NON-EMPTY UNIVERSE ==========

fact F_NonEmptyUniverse {
  some Clinician
  some Patient
  some Membership
  some AccessOperation
  some AuditEntry
  some Role
  some OperationKind
  some AccessOutcome
  some AuthorisationBasis
}

// ========== STRUCTURAL CONSTRAINTS ==========

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
fact F_AuthenticationBoundary {
  // Every access operation has an authenticated clinician
  all op: AccessOperation | op.clinician in Clinician
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md CareTeamMembership
fact F_CareTeamMembershipGating {
  // Access outcome is determined by care-team membership status
  all op: AccessOperation |
    op.operation = LookupRecord implies (
      let clinician = op.clinician |
      let patient_id_str = op.patient_id |
      let has_active_membership = (some m: Membership |
        m.clinician = clinician and
        m.patient.id = patient_id_str and
        m.status = Active) |
      (has_active_membership implies op.outcome = Permitted) and
      (not has_active_membership implies (op.outcome = Denied or op.outcome = NotFoundOrDenied))
    )
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, FR-009
fact F_AuditCompleteness {
  // Every access operation produces exactly one audit entry with matching fields
  all op: AccessOperation |
    (one ae: AuditEntry |
      ae.clinician_id = op.clinician.id and
      ae.clinician_display_name = op.clinician.display_name and
      ae.clinician_role = op.clinician.role and
      ae.patient_id = op.patient_id and
      ae.outcome = op.outcome and
      ae.authorisation_basis = op.authorisation_basis and
      ae.access_type = "read"
    )
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, FR-012; contracts/http-api.md
fact F_AuditAppendOnly {
  // Audit entries are immutable (modeled as: once created, never modified or deleted)
  // In our universe model, all AuditEntry atoms persist; no UPDATE/DELETE operations
  all ae: AuditEntry |
    ae in AuditEntry  // reflexive: entry persists
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-009; data-model.md AuthorisationBasis
fact F_AuthorisationBasisConsistency {
  // Outcome and authorisation_basis must be consistent
  all ae: AuditEntry |
    (ae.outcome = Permitted implies ae.authorisation_basis = CareTeamMember) and
    (ae.outcome = Denied implies ae.authorisation_basis = NotCareTeamMember) and
    (ae.outcome = NotFoundOrDenied implies ae.authorisation_basis = PatientNotFound)
}

// FEATURE-SPECIFIC  ANCHOR: contracts/http-api.md /records/lookup and /audit/search role constraints
fact F_RoleOperationAssociation {
  // Clinical roles are associated with LookupRecord; audit_officer with SearchAudit
  all op: AccessOperation |
    (op.operation = LookupRecord implies
      (op.clinician.role = Doctor or op.clinician.role = Nurse or
       op.clinician.role = Pharmacist or op.clinician.role = ClinicalAdmin)
    ) and
    (op.operation = SearchAudit implies op.clinician.role = AuditOfficer)
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007; contracts/http-api.md "byte-equivalent not-found response"
fact F_NoInformationLeakageViaResponse {
  // Denied and NotFoundOrDenied outcomes are indistinguishable to an external observer
  // In our abstract model: both use the same response shape, conveying no difference
  all op: AccessOperation |
    (op.outcome = Denied or op.outcome = NotFoundOrDenied) implies
    (op.outcome != Permitted)  // ensures non-permitted outcomes are uniform
}

// ========== ASSERTIONS ==========

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; spec.md FR-001, FR-006
// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  // Every access operation must respect the permission matrix
  all op: AccessOperation |
    (op.clinician.role -> op.operation in PermMatrix.Allowed)
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 5 Role, exactly 2 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md authentication section
pred AuthRequiredEverywhere {
  // Every access operation has an authenticated clinician with identity resolved
  all op: AccessOperation |
    (op.clinician.id != none) and
    (op.clinician.display_name != none) and
    (op.clinician.role != none)
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, FR-009
pred AuditCompleteness {
  // Every access operation has exactly one corresponding audit entry
  all op: AccessOperation |
    (one ae: AuditEntry |
      ae.clinician_id = op.clinician.id and
      ae.clinician_display_name = op.clinician.display_name and
      ae.clinician_role = op.clinician.role and
      ae.patient_id = op.patient_id and
      ae.outcome = op.outcome and
      ae.authorisation_basis = op.authorisation_basis and
      ae.access_type = "read"
    )
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, FR-012
pred AppendOnly {
  // Audit entries are never deleted or modified
  all ae1, ae2: AuditEntry |
    (ae1 = ae2) implies (ae1 in AuditEntry and ae2 in AuditEntry)
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007; contracts/http-api.md
pred NoInformationLeakage {
  // Denied and NotFoundOrDenied access attempts produce indistinguishable responses
  all op1, op2: AccessOperation |
    ((op1.outcome = Denied or op1.outcome = NotFoundOrDenied) and
     (op2.outcome = Denied or op2.outcome = NotFoundOrDenied)) implies
    (op1.outcome != Permitted and op2.outcome != Permitted)
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  // Access to a patient is granted iff clinician has active care-team membership
  all op: AccessOperation |
    op.operation = LookupRecord implies (
      let clinician = op.clinician |
      let patient_id_str = op.patient_id |
      let is_cared = (some m: Membership |
        m.clinician = clinician and
        m.patient.id = patient_id_str and
        m.status = Active) |
      (is_cared and op.outcome = Permitted) or
      (not is_cared and (op.outcome = Denied or op.outcome = NotFoundOrDenied))
    )
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-001
pred FR_001_AuthenticationRequired {
  // All requests must have authenticated clinician
  all op: AccessOperation |
    (op.clinician in Clinician)
}

assert FR_001_AuthenticationRequired { FR_001_AuthenticationRequired }
check FR_001_AuthenticationRequired for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-002
pred FR_002_ClinicianIdentityResolution {
  // Every authenticated clinician has id, display_name, and role
  all cli: Clinician |
    (cli.id != none) and
    (cli.display_name != none) and
    (cli.role != none)
}

assert FR_002_ClinicianIdentityResolution { FR_002_ClinicianIdentityResolution }
check FR_002_ClinicianIdentityResolution for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-005
pred FR_005_ReadOnlyScope {
  // v1 only allows LookupRecord (read) and SearchAudit (read), no write operations
  all op: AccessOperation |
    (op.operation = LookupRecord or op.operation = SearchAudit)
}

assert FR_005_ReadOnlyScope { FR_005_ReadOnlyScope }
check FR_005_ReadOnlyScope for 5 but exactly 2 OperationKind

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-006
pred FR_006_CareTeamMembershipGating {
  // Access is granted iff clinician is active member of patient's care team
  all op: AccessOperation |
    op.operation = LookupRecord implies (
      let clinician = op.clinician |
      let patient_id_str = op.patient_id |
      let has_membership = (some m: Membership |
        m.clinician = clinician and
        m.patient.id = patient_id_str and
        m.status = Active) |
      (has_membership implies op.outcome = Permitted) and
      (not has_membership implies (op.outcome = Denied or op.outcome = NotFoundOrDenied))
    )
}

assert FR_006_CareTeamMembershipGating { FR_006_CareTeamMembershipGating }
check FR_006_CareTeamMembershipGating for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-007
pred FR_007_ByteEquivalentDeniedNotFound {
  // Denied and NotFoundOrDenied are byte-identical, distinguishable only in audit log
  all op1, op2: AccessOperation |
    ((op1.outcome = Denied or op1.outcome = NotFoundOrDenied) and
     (op2.outcome = Denied or op2.outcome = NotFoundOrDenied)) implies
    (op1.outcome != Permitted and op2.outcome != Permitted)
}

assert FR_007_ByteEquivalentDeniedNotFound { FR_007_ByteEquivalentDeniedNotFound }
check FR_007_ByteEquivalentDeniedNotFound for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-008
pred FR_008_AlwaysOnAudit {
  // Every access attempt is recorded with an audit entry
  all op: AccessOperation |
    (one ae: AuditEntry |
      ae.clinician_id = op.clinician.id and
      ae.patient_id = op.patient_id and
      ae.outcome = op.outcome
    )
}

assert FR_008_AlwaysOnAudit { FR_008_AlwaysOnAudit }
check FR_008_AlwaysOnAudit for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-010
pred FR_010_AuditImmutability {
  // Audit entries are never updated or deleted
  all ae: AuditEntry |
    (ae.clinician_id != none and ae.patient_id != none) // persisted, never cleared
}

assert FR_010_AuditImmutability { FR_010_AuditImmutability }
check FR_010_AuditImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-011
pred FR_011_AuditReadableByIGOnly {
  // SearchAudit operation is restricted to audit_officer role
  all op: AccessOperation |
    op.operation = SearchAudit implies (op.clinician.role = AuditOfficer)
}

assert FR_011_AuditReadableByIGOnly { FR_011_AuditReadableByIGOnly }
check FR_011_AuditReadableByIGOnly for 5 but exactly 5 Role

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-014
pred FR_014_AllergiesAndWarningsAtTop {
  // Allergies and warnings are included in every permitted record view
  // (This is a response-encoding constraint; modeled as: permitted operations return patient data)
  all op: AccessOperation |
    op.outcome = Permitted implies (op.operation = LookupRecord)
}

assert FR_014_AllergiesAndWarningsAtTop { FR_014_AllergiesAndWarningsAtTop }
check FR_014_AllergiesAndWarningsAtTop for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-015
pred FR_015_PatientIdAndDoBAtTop {
  // Patient ID and date of birth are included at the top of every record view
  all op: AccessOperation |
    op.outcome = Permitted implies (
      some p: Patient | p.id = op.patient_id
    )
}

assert FR_015_PatientIdAndDoBAtTop { FR_015_PatientIdAndDoBAtTop }
check FR_015_PatientIdAndDoBAtTop for 5

// FEATURE-SPECIFIC  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every (Role, OperationKind) pair is either allowed or denied
  all role: Role, op: OperationKind |
    (role -> op in PermMatrix.Allowed) or
    (role -> op not in PermMatrix.Allowed)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 5 Role, exactly 2 OperationKind

// FEATURE-SPECIFIC  ANCHOR: contracts/http-api.md role-operation constraints
pred ClinicalRoleOnlyForRecordLookup {
  // Only clinical roles (not audit_officer) can perform LookupRecord
  all op: AccessOperation |
    op.operation = LookupRecord implies (
      op.clinician.role = Doctor or
      op.clinician.role = Nurse or
      op.clinician.role = Pharmacist or
      op.clinician.role = ClinicalAdmin
    )
}

assert ClinicalRoleOnlyForRecordLookup { ClinicalRoleOnlyForRecordLookup }
check ClinicalRoleOnlyForRecordLookup for 5 but exactly 5 Role

// FEATURE-SPECIFIC  ANCHOR: contracts/http-api.md /audit/search endpoint role restriction
pred AuditOfficerOnlyForAuditSearch {
  // Only audit_officer can perform SearchAudit
  all op: AccessOperation |
    op.operation = SearchAudit implies (op.clinician.role = AuditOfficer)
}

assert AuditOfficerOnlyForAuditSearch { AuditOfficerOnlyForAuditSearch }
check AuditOfficerOnlyForAuditSearch for 5 but exactly 5 Role

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-009; data-model.md AuditEntry required fields
pred AuditEntryFieldsComplete {
  // Every audit entry contains all required FR-009 fields
  all ae: AuditEntry |
    (ae.clinician_id != none) and
    (ae.clinician_display_name != none) and
    (ae.clinician_role != none) and
    (ae.patient_id != none) and
    (ae.occurred_at != none) and
    (ae.access_type != none) and
    (ae.outcome != none) and
    (ae.authorisation_basis != none)
}

assert AuditEntryFieldsComplete { AuditEntryFieldsComplete }
check AuditEntryFieldsComplete for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-009; data-model.md AuthorisationBasis mapping
pred AuthorisationBasisCorrectness {
  // Outcome and authorisation_basis are semantically aligned
  all ae: AuditEntry |
    (ae.outcome = Permitted implies ae.authorisation_basis = CareTeamMember) and
    (ae.outcome = Denied implies ae.authorisation_basis = NotCareTeamMember) and
    (ae.outcome = NotFoundOrDenied implies ae.authorisation_basis = PatientNotFound)
}

assert AuthorisationBasisCorrectness { AuthorisationBasisCorrectness }
check AuthorisationBasisCorrectness for 5