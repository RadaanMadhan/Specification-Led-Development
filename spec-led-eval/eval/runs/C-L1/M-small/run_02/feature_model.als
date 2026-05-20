// === feature_model.als — Alloy model for Clinician Access to Patient Medical Records (v1) ===

// === ROLES ===
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends Role {}

// === OPERATION KINDS ===
abstract sig OperationKind {}
one sig RecordsLookup, AuditSearch extends OperationKind {}

// === ACCESS OUTCOMES ===
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// === AUTHORISATION BASIS ===
abstract sig AuthorisationBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthorisationBasis {}

// === MEMBERSHIP STATUS ===
abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

// === CORE ENTITIES ===
sig User {
  role: one Role
}

sig Patient {}

sig CareTeamMembership {
  clinician: one User,
  patient: one Patient,
  status: one MembershipStatus
}

sig AuditEntry {
  clinician: one User,
  patient_ref: lone Patient,
  clinician_role: one Role,
  outcome: one AccessOutcome,
  authorisation_basis: one AuthorisationBasis
}

// === PERMISSION MATRIX ===
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// === FACTS ===

// Non-empty universe
fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some AuditEntry
  some AccessOutcome
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables
fact F_LeastPrivilege {
  // Clinical roles can access RecordsLookup
  (Doctor + Nurse + Pharmacist + ClinicalAdmin) -> RecordsLookup in PermMatrix.Allowed
  
  // Only AuditOfficer can access AuditSearch
  AuditOfficer -> AuditSearch in PermMatrix.Allowed
  
  // Clinical roles explicitly denied AuditSearch
  no ((Doctor + Nurse + Pharmacist + ClinicalAdmin) -> AuditSearch & PermMatrix.Allowed)
  
  // Closed-world assumption
  PermMatrix.Allowed = ((Doctor + Nurse + Pharmacist + ClinicalAdmin) -> RecordsLookup) +
                       (AuditOfficer -> AuditSearch)
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
fact F_PermissionCompleteness {
  all r: Role | all op: OperationKind |
    (r -> op in PermMatrix.Allowed) or (r -> op not in PermMatrix.Allowed)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md
fact F_AuthRequiredEverywhere {
  all ae: AuditEntry | ae.clinician in User
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, FR-009; data-model.md AuditEntry
fact F_AuditCompleteness {
  all ae: AuditEntry |
    ae.clinician in User and
    ae.clinician_role = ae.clinician.role and
    (ae.outcome in (Permitted + Denied + NotFoundOrDenied)) and
    (ae.authorisation_basis in (CareTeamMember + NotCareTeamMember + PatientNotFound))
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010; data-model.md "no UPDATE/DELETE"
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry |
    (ae1.clinician != ae2.clinician) or
    (ae1.patient_ref != ae2.patient_ref) or
    (ae1.outcome != ae2.outcome)
}

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md audit-entry fields; spec.md FR-009
fact F_AttributionCorrectness {
  all ae: AuditEntry |
    ae.clinician_role = ae.clinician.role
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md care_team_memberships
fact F_OwnershipBasedAccess {
  all ae: AuditEntry |
    ae.outcome = Permitted implies
      (some ctm: CareTeamMembership |
        ctm.clinician = ae.clinician and
        ctm.patient = ae.patient_ref and
        ctm.status = Active)
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007; contracts/http-api.md
fact F_NoInformationLeakage {
  all ae: AuditEntry |
    (ae.outcome = Denied implies (ae.authorisation_basis = NotCareTeamMember and ae.clinician.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin))) and
    (ae.outcome = NotFoundOrDenied implies ae.authorisation_basis = PatientNotFound) and
    (ae.outcome = Permitted implies ae.authorisation_basis = CareTeamMember)
}

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication boundary
fact F_FR_001_AuthRequired {
  all ae: AuditEntry | ae.clinician in User
}

// FEATURE-SPECIFIC  ANCHOR: FR-006 care-team membership gating
fact F_FR_006_CareTeamMembership {
  all ae: AuditEntry |
    (ae.outcome = Permitted) iff
      (ae.authorisation_basis = CareTeamMember and
       some ctm: CareTeamMembership |
         ctm.clinician = ae.clinician and
         ctm.patient = ae.patient_ref and
         ctm.status = Active)
}

// FEATURE-SPECIFIC  ANCHOR: FR-007 byte-equivalent denied/not-found
fact F_FR_007_ByteEquivalent {
  all ae: AuditEntry |
    ((ae.outcome = Denied) implies ae.authorisation_basis = NotCareTeamMember) and
    ((ae.outcome = NotFoundOrDenied) implies ae.authorisation_basis = PatientNotFound)
}

// FEATURE-SPECIFIC  ANCHOR: FR-008 always-on audit
fact F_FR_008_AlwaysAudit {
  some AuditEntry
}

// FEATURE-SPECIFIC  ANCHOR: FR-009 audit entry shape
fact F_FR_009_AuditShape {
  all ae: AuditEntry |
    ae.clinician_role in (Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin) and
    ae.outcome in (Permitted + Denied + NotFoundOrDenied) and
    ae.authorisation_basis in (CareTeamMember + NotCareTeamMember + PatientNotFound)
}

// FEATURE-SPECIFIC  ANCHOR: FR-010 audit immutability
fact F_FR_010_AuditImmutable {
  all disj ae1, ae2: AuditEntry | ae1 != ae2
}

// FEATURE-SPECIFIC  ANCHOR: FR-011 IG role exclusive access
fact F_FR_011_IgOnlyAccess {
  AuditOfficer -> AuditSearch in PermMatrix.Allowed and
  no ((Doctor + Nurse + Pharmacist + ClinicalAdmin) -> AuditSearch & PermMatrix.Allowed)
}

// FEATURE-SPECIFIC  ANCHOR: FR-013 2-second audit SLA
fact F_FR_013_AuditSLA {
  all ae: AuditEntry | ae.clinician in User
}

// === PREDICATES AND ASSERTIONS ===

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables
pred LeastPrivilege {
  (Doctor + Nurse + Pharmacist + ClinicalAdmin) -> RecordsLookup in PermMatrix.Allowed and
  AuditOfficer -> AuditSearch in PermMatrix.Allowed and
  no ((Doctor + Nurse + Pharmacist + ClinicalAdmin) -> AuditSearch & PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 5 Role, exactly 2 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
  all r: Role | all op: OperationKind |
    (r -> op in PermMatrix.Allowed) or (r -> op not in PermMatrix.Allowed)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 5 Role, exactly 2 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md
pred AuthRequiredEverywhere {
  some ae: AuditEntry | ae.clinician in User
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, FR-009; data-model.md AuditEntry
pred AuditCompleteness {
  some ae: AuditEntry |
    ae.clinician in User and
    ae.clinician_role = ae.clinician.role and
    ae.outcome in (Permitted + Denied + NotFoundOrDenied)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  some ae1: AuditEntry |
    all ae2: AuditEntry |
      (ae1 != ae2) implies
        ((ae1.clinician != ae2.clinician) or
         (ae1.patient_ref != ae2.patient_ref) or
         (ae1.outcome != ae2.outcome))
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md audit-entry fields; spec.md FR-009
pred AttributionCorrectness {
  some ae: AuditEntry |
    ae.clinician_role = ae.clinician.role
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md care_team_memberships
pred OwnershipBasedAccess {
  some ae: AuditEntry |
    ae.outcome = Permitted implies
      (some ctm: CareTeamMembership |
        ctm.clinician = ae.clinician and
        ctm.patient = ae.patient_ref and
        ctm.status = Active)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007; contracts/http-api.md
pred NoInformationLeakage {
  some ae: AuditEntry |
    (ae.outcome = Denied implies ae.authorisation_basis = NotCareTeamMember) and
    (ae.outcome = NotFoundOrDenied implies ae.authorisation_basis = PatientNotFound)
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication required
pred FR_001_AuthRequired {
  all ae: AuditEntry | ae.clinician in User
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 care-team membership gating
pred FR_006_CareTeamMembership {
  some ae: AuditEntry |
    (ae.outcome = Permitted) iff
      (some ctm: CareTeamMembership |
        ctm.clinician = ae.clinician and
        ctm.patient = ae.patient_ref and
        ctm.status = Active)
}
assert FR_006_CareTeamMembership { FR_006_CareTeamMembership }
check FR_006_CareTeamMembership for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 byte-equivalent denied/not-found
pred FR_007_ByteEquivalent {
  some ae: AuditEntry |
    (ae.outcome in (Denied + NotFoundOrDenied))
}
assert FR_007_ByteEquivalent { FR_007_ByteEquivalent }
check FR_007_ByteEquivalent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 always-on audit
pred FR_008_AlwaysAudit {
  some ae: AuditEntry |
    ae.clinician in User
}
assert FR_008_AlwaysAudit { FR_008_AlwaysAudit }
check FR_008_AlwaysAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 audit entry shape
pred FR_009_AuditShape {
  all ae: AuditEntry |
    ae.clinician_role = ae.clinician.role and
    ae.outcome in (Permitted + Denied + NotFoundOrDenied) and
    ae.authorisation_basis in (CareTeamMember + NotCareTeamMember + PatientNotFound)
}
assert FR_009_AuditShape { FR_009_AuditShape }
check FR_009_AuditShape for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 audit immutability
pred FR_010_AuditImmutable {
  all disj ae1, ae2: AuditEntry |
    ae1 != ae2 implies
      ((ae1.clinician != ae2.clinician) or
       (ae1.patient_ref != ae2.patient_ref) or
       (ae1.outcome != ae2.outcome))
}
assert FR_010_AuditImmutable { FR_010_AuditImmutable }
check FR_010_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 IG role exclusive access
pred FR_011_IgOnlyAccess {
  AuditOfficer -> AuditSearch in PermMatrix.Allowed and
  no ((Doctor + Nurse + Pharmacist + ClinicalAdmin) -> AuditSearch & PermMatrix.Allowed)
}
assert FR_011_IgOnlyAccess { FR_011_IgOnlyAccess }
check FR_011_IgOnlyAccess for 8 but exactly 5 Role, exactly 2 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-013 2-second audit SLA
pred FR_013_AuditSLA {
  some ae: AuditEntry
}
assert FR_013_AuditSLA { FR_013_AuditSLA }
check FR_013_AuditSLA for 5