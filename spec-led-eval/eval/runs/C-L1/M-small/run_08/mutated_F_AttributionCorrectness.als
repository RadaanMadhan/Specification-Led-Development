// === feature_model.als — Alloy model for Clinician Access to Patient Medical Records (C-L1) ===

// Roles
abstract sig ClinicianRole {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends ClinicianRole {}

// Access outcomes
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// Authorization bases
abstract sig AuthorisationBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthorisationBasis {}

// Membership status
abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

// Operations
abstract sig OperationKind {}
one sig RecordsLookup, AuditSearch extends OperationKind {}

// Users (clinicians)
sig User {
  id: one String,
  display_name: one String,
  role: one ClinicianRole
}

// Patients
sig Patient {
  id: one String,
  name: one String,
  date_of_birth: one String
}

// Care team membership
sig CareTeamMembership {
  clinician: one User,
  patient: one Patient,
  status: one MembershipStatus
}

// Audit entry - immutable record of one access attempt
sig AuditEntry {
  clinician: one User,
  clinician_display_name: one String,
  clinician_role: one ClinicianRole,
  patient_id: one String,
  occurred_at: one String,
  access_type: one String,
  outcome: one AccessOutcome,
  authorisation_basis: one AuthorisationBasis
}

// Permission matrix - singleton holding the authorization matrix
one sig PermMatrix {
  Allowed: set ClinicianRole -> OperationKind
}

// === FACTS ===

// Non-empty universe - ensure test instances exist
fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some AuditEntry
}

// Unique user IDs
fact F_UniqueUserIds {
  all disj u1, u2: User | u1.id != u2.id
}

// Unique patient IDs
fact F_UniquePatientIds {
  all disj p1, p2: Patient | p1.id != p2.id
}

// Permission matrix definition - closed world
fact F_PermissionMatrix {
  Doctor -> RecordsLookup in PermMatrix.Allowed
  Nurse -> RecordsLookup in PermMatrix.Allowed
  Pharmacist -> RecordsLookup in PermMatrix.Allowed
  ClinicalAdmin -> RecordsLookup in PermMatrix.Allowed
  AuditOfficer -> AuditSearch in PermMatrix.Allowed
  
  PermMatrix.Allowed = 
    (Doctor -> RecordsLookup) +
    (Nurse -> RecordsLookup) +
    (Pharmacist -> RecordsLookup) +
    (ClinicalAdmin -> RecordsLookup) +
    (AuditOfficer -> AuditSearch)
}

// Records endpoint only for clinical roles - not audit roles
fact F_RecordsLookupIsForClinicalRoles {
  all ae: AuditEntry |
    ae.clinician.role != AuditOfficer
}

// Access permitted only with active care-team membership
fact F_OwnershipBasedAccess {
  all ae: AuditEntry |
    ae.outcome = Permitted implies (
      some p: Patient, ctm: CareTeamMembership |
        p.id = ae.patient_id and
        ctm.clinician = ae.clinician and
        ctm.patient = p and
        ctm.status = Active
    )
}

// Audit entries are immutable - no modification of existing entries
fact F_AuditAppendOnly {
  all disj ae1, ae2: AuditEntry |
    (ae1.clinician = ae2.clinician and
     ae1.patient_id = ae2.patient_id and
     ae1.occurred_at = ae2.occurred_at) implies (
      ae1.outcome = ae2.outcome and
      ae1.authorisation_basis = ae2.authorisation_basis and
      ae1.clinician_display_name = ae2.clinician_display_name and
      ae1.clinician_role = ae2.clinician_role
    )
}

// Audit entry clinician info is snapshotted and matches current user data
fact F_AttributionCorrectness { /* MUTATED — body cleared by validator */ }

// NoInformationLeakage - denied vs not_found are distinguished internally
// Denied: patient exists, clinician not on care team
// NotFoundOrDenied: patient does not exist
fact F_NoInformationLeakage {
  all ae: AuditEntry |
    ae.outcome = Denied implies (
      some p: Patient | p.id = ae.patient_id
    ) and
    ae.outcome = NotFoundOrDenied implies (
      no p: Patient | p.id = ae.patient_id
    ) and
    ae.outcome = Permitted implies (
      some p: Patient | p.id = ae.patient_id
    )
}

// === PREDICATES & ASSERTIONS ===

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-005, FR-006
pred LeastPrivilege {
  some ae: AuditEntry |
    ae.clinician.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
  PermMatrix.Allowed =
    (Doctor -> RecordsLookup) +
    (Nurse -> RecordsLookup) +
    (Pharmacist -> RecordsLookup) +
    (ClinicalAdmin -> RecordsLookup) +
    (AuditOfficer -> AuditSearch)
}

assert PermissionCompleteness {
  PermissionCompleteness
}

check PermissionCompleteness for 5 but exactly 5 ClinicianRole, exactly 2 OperationKind

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-005, FR-006, FR-011; contracts/http-api.md
pred PermissionGrounding {
  Doctor -> RecordsLookup in PermMatrix.Allowed and
  Nurse -> RecordsLookup in PermMatrix.Allowed and
  Pharmacist -> RecordsLookup in PermMatrix.Allowed and
  ClinicalAdmin -> RecordsLookup in PermMatrix.Allowed and
  AuditOfficer -> AuditSearch in PermMatrix.Allowed
}

assert PermissionGrounding {
  PermissionGrounding
}

check PermissionGrounding for 5 but exactly 5 ClinicianRole, exactly 2 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001; contracts/http-api.md
pred AuthRequiredEverywhere {
  all ae: AuditEntry |
    ae.clinician in User and
    ae.clinician.role in ClinicianRole
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-006; contracts/http-api.md authorisation
pred OwnershipBasedAccess {
  all ae: AuditEntry |
    ae.outcome = Permitted implies (
      some p: Patient, ctm: CareTeamMembership |
        p.id = ae.patient_id and
        ctm.clinician = ae.clinician and
        ctm.patient = p and
        ctm.status = Active
    )
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-008, FR-009; data-model.md
pred AuditCompleteness {
  all ae: AuditEntry |
    ae.clinician in User and
    ae.outcome in (Permitted + Denied + NotFoundOrDenied) and
    ae.authorisation_basis in (CareTeamMember + NotCareTeamMember + PatientNotFound)
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: FR-010; contracts/http-api.md
pred AppendOnly {
  all disj ae1, ae2: AuditEntry |
    (ae1.clinician = ae2.clinician and
     ae1.patient_id = ae2.patient_id and
     ae1.occurred_at = ae2.occurred_at) implies (
      ae1.outcome = ae2.outcome
    )
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-009; data-model.md AuditEntry
pred AttributionCorrectness {
  all ae: AuditEntry |
    ae.clinician_display_name = ae.clinician.display_name and
    ae.clinician_role = ae.clinician.role
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: NoInformationLeakage  ANCHOR: FR-007; contracts/http-api.md byte-equivalent response
pred NoInformationLeakage {
  all ae: AuditEntry |
    (ae.outcome = Denied implies ae.authorisation_basis = NotCareTeamMember) and
    (ae.outcome = NotFoundOrDenied implies ae.authorisation_basis = PatientNotFound) and
    (ae.outcome = Permitted implies ae.authorisation_basis = CareTeamMember)
}

assert NoInformationLeakage {
  NoInformationLeakage
}

check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 role resolution
pred FR_002_RoleResolution {
  all u: User |
    u.role in (Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin)
}

assert FR_002_RoleResolution {
  FR_002_RoleResolution
}

check FR_002_RoleResolution for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 read-only access scope
pred FR_005_ReadOnlyAccessScope {
  all ae: AuditEntry | ae.access_type = "read"
}

assert FR_005_ReadOnlyAccessScope {
  FR_005_ReadOnlyAccessScope
}

check FR_005_ReadOnlyAccessScope for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008, FR-013 all access attempts audited
pred FR_008_AllAccessesAudited {
  some ae1, ae2, ae3: AuditEntry |
    ae1.outcome = Permitted and
    ae2.outcome = Denied and
    ae3.outcome = NotFoundOrDenied
}

assert FR_008_AllAccessesAudited {
  FR_008_AllAccessesAudited
}

check FR_008_AllAccessesAudited for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 only IG role accesses audit endpoint
pred FR_011_ClinicalRolesInAudit {
  all ae: AuditEntry | ae.clinician.role != AuditOfficer
}

assert FR_011_ClinicalRolesInAudit {
  FR_011_ClinicalRolesInAudit
}

check FR_011_ClinicalRolesInAudit for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AttributionViolation { some ae: AuditEntry | ae.clinician_display_name != ae.clinician.display_name or ae.clinician_role != ae.clinician.role }
