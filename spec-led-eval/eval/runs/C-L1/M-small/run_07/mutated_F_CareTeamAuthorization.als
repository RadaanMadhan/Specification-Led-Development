// === feature_model.als — Alloy model for Clinician Access to Patient Medical Records (C-L1) ===

// ===== ROLES =====
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, AuditOfficer extends Role {}

// ===== OPERATIONS =====
abstract sig OperationKind {}
one sig RecordsLookup, AuditSearch extends OperationKind {}

// ===== ACCESS OUTCOMES =====
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// ===== AUTHORIZATION BASIS =====
abstract sig AuthorisationBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthorisationBasis {}

// ===== CORE ENTITIES =====
sig Clinician {
  role: one Role
}

sig Patient {}

abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

sig CareTeamMembership {
  clinician: one Clinician,
  patient: one Patient,
  status: one MembershipStatus
}

sig AuditEntry {
  clinician: one Clinician,
  patient: one Patient,
  outcome: one AccessOutcome,
  basis: one AuthorisationBasis
}

sig AccessOperation {
  caller: one Clinician,
  operationKind: one OperationKind,
  patient: one Patient,
  auditEntry: one AuditEntry
}

// ===== PERMISSION MATRIX =====
one sig PermMatrix {
  allowed: set Role -> OperationKind
}

// ===== UNIVERSE CONSTRAINT =====
fact F_NonEmptyUniverse {
  some Clinician
  some Patient
  some AuditEntry
  some AccessOperation
  some CareTeamMembership
}

// ===== CORE FACTS =====

// PATTERN: PermissionCompleteness, PermissionGrounding  ANCHOR: contracts/http-api.md; spec.md FR-006, FR-011
fact F_PermissionMatrix {
  // Clinical roles can attempt RecordsLookup
  Doctor -> RecordsLookup in PermMatrix.allowed
  Nurse -> RecordsLookup in PermMatrix.allowed
  Pharmacist -> RecordsLookup in PermMatrix.allowed
  ClinicalAdmin -> RecordsLookup in PermMatrix.allowed
  
  // AuditOfficer cannot attempt RecordsLookup
  not (AuditOfficer -> RecordsLookup in PermMatrix.allowed)
  
  // Clinical roles cannot attempt AuditSearch
  not (Doctor -> AuditSearch in PermMatrix.allowed)
  not (Nurse -> AuditSearch in PermMatrix.allowed)
  not (Pharmacist -> AuditSearch in PermMatrix.allowed)
  not (ClinicalAdmin -> AuditSearch in PermMatrix.allowed)
  
  // AuditOfficer can attempt AuditSearch
  AuditOfficer -> AuditSearch in PermMatrix.allowed
  
  // Closed-world assumption: exactly these allowed pairs
  PermMatrix.allowed = (Doctor -> RecordsLookup) + (Nurse -> RecordsLookup) +
                       (Pharmacist -> RecordsLookup) + (ClinicalAdmin -> RecordsLookup) +
                       (AuditOfficer -> AuditSearch)
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; spec.md FR-006, FR-011
fact F_LeastPrivilege {
  all op: AccessOperation |
    not (op.caller.role -> op.operationKind in PermMatrix.allowed) implies
      (op.auditEntry.outcome in Denied + NotFoundOrDenied)
}

// PATTERN: AuditCompleteness + AttributionCorrectness  ANCHOR: spec.md FR-008, FR-009
fact F_AuditCompleteness {
  all op: AccessOperation |
    op.auditEntry.clinician = op.caller and
    op.auditEntry.patient = op.patient
}

// PATTERN: OwnershipBasedAccess (care-team-based authorization)  ANCHOR: spec.md FR-006; data-model.md CareTeamMembership
fact F_CareTeamAuthorization { /* MUTATED — body cleared by validator */ }

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-011; contracts/http-api.md /audit/search
fact F_IGRoleRestriction {
  all op: AccessOperation |
    op.operationKind = AuditSearch implies op.caller.role = AuditOfficer
}

// ===== PREDICATES & ASSERTIONS =====

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; spec.md FR-006, FR-011
pred LeastPrivilege {
  all op: AccessOperation |
    not (op.caller.role -> op.operationKind in PermMatrix.allowed) implies
      (op.auditEntry.outcome in Denied + NotFoundOrDenied)
}

// PATTERN: PermissionGrounding  ANCHOR: contracts/http-api.md; spec.md FR-006, FR-011
pred PermissionGrounding {
  PermMatrix.allowed = (Doctor -> RecordsLookup) + (Nurse -> RecordsLookup) +
                       (Pharmacist -> RecordsLookup) + (ClinicalAdmin -> RecordsLookup) +
                       (AuditOfficer -> AuditSearch)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all op: AccessOperation | some op.caller
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, FR-009
pred AuditCompleteness {
  all op: AccessOperation |
    op.auditEntry.clinician = op.caller and
    op.auditEntry.patient = op.patient
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, FR-012
pred AppendOnly {
  all ae: AuditEntry |
    ae.outcome in Permitted + Denied + NotFoundOrDenied and
    ae.basis in CareTeamMember + NotCareTeamMember + PatientNotFound
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md AuditEntry
pred AttributionCorrectness {
  all op: AccessOperation |
    op.auditEntry.clinician = op.caller and
    op.auditEntry.patient = op.patient
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  all op: AccessOperation |
    op.operationKind = RecordsLookup implies (
      op.auditEntry.outcome = Permitted iff
      (some m: CareTeamMembership |
        m.clinician = op.caller and m.patient = op.patient and m.status = Active)
    )
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007; contracts/http-api.md
pred NoInformationLeakage {
  all op: AccessOperation |
    (op.auditEntry.outcome = Denied or op.auditEntry.outcome = NotFoundOrDenied) implies
      (no other_op: AccessOperation |
        other_op.caller = op.caller and
        other_op.operationKind = op.operationKind and
        other_op.auditEntry.outcome = Permitted)
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-001; contracts/http-api.md
pred FR_001_AuthenticationRequired {
  all op: AccessOperation | some op.caller
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-006; contracts/http-api.md /records/lookup
pred FR_006_CareTeamMembershipGating {
  all op: AccessOperation |
    op.operationKind = RecordsLookup implies (
      op.auditEntry.outcome = Permitted iff
      (some m: CareTeamMembership |
        m.clinician = op.caller and
        m.patient = op.patient and
        m.status = Active)
    )
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-008, FR-009; contracts/http-api.md
pred FR_008_AlwaysOnAudit {
  all op: AccessOperation |
    op.auditEntry.clinician = op.caller and
    op.auditEntry.patient = op.patient
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-010; data-model.md AuditEntry
pred FR_010_AuditImmutability {
  all ae: AuditEntry |
    ae.outcome in Permitted + Denied + NotFoundOrDenied and
    ae.basis in CareTeamMember + NotCareTeamMember + PatientNotFound
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-011; contracts/http-api.md /audit/search
pred FR_011_IGAuditAccess {
  all op: AccessOperation |
    op.operationKind = AuditSearch implies op.caller.role = AuditOfficer
}

// ===== ASSERTIONS =====

assert LeastPrivilege { LeastPrivilege }
assert PermissionGrounding { PermissionGrounding }
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
assert AuditCompleteness { AuditCompleteness }
assert AppendOnly { AppendOnly }
assert AttributionCorrectness { AttributionCorrectness }
assert OwnershipBasedAccess { OwnershipBasedAccess }
assert NoInformationLeakage { NoInformationLeakage }
assert FR_001_AuthenticationRequired { FR_001_AuthenticationRequired }
assert FR_006_CareTeamMembershipGating { FR_006_CareTeamMembershipGating }
assert FR_008_AlwaysOnAudit { FR_008_AlwaysOnAudit }
assert FR_010_AuditImmutability { FR_010_AuditImmutability }
assert FR_011_IGAuditAccess { FR_011_IGAuditAccess }

// ===== CHECKS =====

check LeastPrivilege for 5
check PermissionGrounding for 5
check AuthRequiredEverywhere for 5
check AuditCompleteness for 5
check AppendOnly for 5
check AttributionCorrectness for 5
check OwnershipBasedAccess for 5
check NoInformationLeakage for 5
check FR_001_AuthenticationRequired for 5
check FR_006_CareTeamMembershipGating for 5
check FR_008_AlwaysOnAudit for 5
check FR_010_AuditImmutability for 5
check FR_011_IGAuditAccess for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_UnauthorizedLookup { some op: AccessOperation | op.operationKind = RecordsLookup and op.auditEntry.outcome = Permitted and no m: CareTeamMembership | m.clinician = op.caller and m.patient = op.patient and m.status = Active }
