// === Hospital Clinical Record Access Feature Model (C-L2) ===
// Feature: 012-hospital-clinical-records

// ===== Roles =====
abstract sig Role {}
one sig DoctorRole, NurseRole, PharmacistRole, ClinicalAdminRole extends Role {}
one sig HospitalAdministratorRole extends Role {}

// ===== Operation Types =====
abstract sig OperationKind {}
one sig ReadRecord, AddNote, ListAudit extends OperationKind {}

// ===== Access Outcomes =====
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// ===== Authorisation Basis =====
abstract sig AuthorisationBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound, AdministratorRole extends AuthorisationBasis {}

// ===== Note Types =====
abstract sig NoteType {}
one sig Progress, Assessment, Plan, Observation, DischargeSummary extends NoteType {}

// ===== Domain Entities =====

sig User {
  userId: one String,
  displayName: one String,
  userRole: one Role
}

sig Patient {
  patientId: one String
}

sig CareTeamMembership {
  clinician: one User,
  patient: one Patient,
  status: one String  // "active" or "ended"
}

sig ClinicalNote {
  noteId: one String,
  patient: one Patient,
  author: one User,
  authorDisplayName: one String,
  authorRole: one Role,
  body: one String,
  noteType: one NoteType
}

sig AuditEntry {
  auditId: one Int,
  userId: one String,
  displayName: one String,
  userRole: one Role,
  patientIdRequested: one String,
  accessType: one OperationKind,
  noteId: lone String,
  outcome: one AccessOutcome,
  basis: one AuthorisationBasis
}

// ===== Permission Matrix =====
one sig PermMatrix {
  allowed: set Role -> OperationKind
}

// ===== Facts =====

fact F_NonEmptyUniverse {
  some User
  some Patient
  some ClinicalNote
  some AuditEntry
  some CareTeamMembership
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission table; spec.md FR-004, FR-005, FR-017
fact F_PermissionMatrix {
  // Clinical roles: can read records and add notes (subject to care-team membership check)
  DoctorRole -> ReadRecord in PermMatrix.allowed
  DoctorRole -> AddNote in PermMatrix.allowed
  NurseRole -> ReadRecord in PermMatrix.allowed
  NurseRole -> AddNote in PermMatrix.allowed
  PharmacistRole -> ReadRecord in PermMatrix.allowed
  PharmacistRole -> AddNote in PermMatrix.allowed
  ClinicalAdminRole -> ReadRecord in PermMatrix.allowed
  ClinicalAdminRole -> AddNote in PermMatrix.allowed
  
  // Administrator: can only list audit logs
  HospitalAdministratorRole -> ListAudit in PermMatrix.allowed
  
  // Closed-world: no other permissions
  PermMatrix.allowed = (DoctorRole -> ReadRecord) +
                       (DoctorRole -> AddNote) +
                       (NurseRole -> ReadRecord) +
                       (NurseRole -> AddNote) +
                       (PharmacistRole -> ReadRecord) +
                       (PharmacistRole -> AddNote) +
                       (ClinicalAdminRole -> ReadRecord) +
                       (ClinicalAdminRole -> AddNote) +
                       (HospitalAdministratorRole -> ListAudit)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
fact F_AuthRequired {
  all ae: AuditEntry |
    some u: User | u.userId = ae.userId
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012
fact F_AuditOnePerNote {
  all n: ClinicalNote |
    one ae: AuditEntry | ae.noteId = n.noteId and ae.accessType = AddNote and ae.outcome = Permitted
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011 (clinical notes), FR-014 (audit entries)
fact F_NotesAppendOnly {
  all n: ClinicalNote | n in ClinicalNote
}

fact F_AuditAppendOnly {
  all ae: AuditEntry | ae in AuditEntry
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md AuditEntry fields
fact F_AuditAttributionCorrect {
  all ae: AuditEntry |
    all u: User |
      u.userId = ae.userId implies (u.displayName = ae.displayName and u.userRole = ae.userRole)
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006
fact F_DeniedAndNotFoundIdentical {
  // Denied and NotFoundOrDenied must be structurally indistinguishable in response
  all ae: AuditEntry |
    (ae.outcome = Denied or ae.outcome = NotFoundOrDenied) implies
    (ae.accessType = ReadRecord or ae.accessType = AddNote)
}

// PATTERN: PermissionGrounding  ANCHOR: spec.md FRs; contracts/http-api.md
fact F_AllPermissionsGrounded {
  all r: Role |
    all ok: OperationKind |
      (r -> ok) in PermMatrix.allowed implies
      ((r in DoctorRole + NurseRole + PharmacistRole + ClinicalAdminRole and ok in ReadRecord + AddNote) or
       (r = HospitalAdministratorRole and ok = ListAudit))
}

// ===== Predicates =====

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; spec.md FR-004, FR-005
pred LeastPrivilege {
  all r: Role |
    all ok: OperationKind |
      (r -> ok) in PermMatrix.allowed implies
      ((r in (DoctorRole + NurseRole + PharmacistRole + ClinicalAdminRole) and
        ok in (ReadRecord + AddNote)) or
       (r = HospitalAdministratorRole and ok = ListAudit))
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011, FR-014
pred AppendOnly {
  (all n: ClinicalNote | n in ClinicalNote) and
  (all ae: AuditEntry | ae in AuditEntry)
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012
pred AuditCompleteness {
  all n: ClinicalNote |
    one ae: AuditEntry | ae.noteId = n.noteId and ae.accessType = AddNote and ae.outcome = Permitted
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013
pred AttributionCorrectness {
  all ae: AuditEntry |
    all u: User |
      u.userId = ae.userId implies (u.displayName = ae.displayName and u.userRole = ae.userRole)
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006
pred NoInformationLeakage {
  all ae: AuditEntry |
    (ae.outcome = Denied or ae.outcome = NotFoundOrDenied) implies
    (ae.accessType = ReadRecord or ae.accessType = AddNote)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all ae: AuditEntry | some u: User | u.userId = ae.userId
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-004 Care-team membership gates access
pred FR_004_CareTeamGating {
  all u: User |
    let clinicalRoles = DoctorRole + NurseRole + PharmacistRole + ClinicalAdminRole |
      u.userRole in clinicalRoles implies (
        all p: Patient |
          (some ae: AuditEntry |
            ae.userId = u.userId and ae.patientIdRequested = p.patientId and
            (ae.accessType = ReadRecord or ae.accessType = AddNote) and ae.outcome = Permitted)
          implies
          (some ctm: CareTeamMembership | ctm.clinician = u and ctm.patient = p and ctm.status = "active")
      )
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-005 Administrator cannot access clinical records
pred FR_005_AdminCannotReadClinicalContent {
  all u: User |
    u.userRole = HospitalAdministratorRole implies (
      all ae: AuditEntry | ae.userId = u.userId implies ae.accessType = ListAudit
    )
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-017 Only administrator can list audit
pred FR_017_AuditListAdminOnly {
  all ae: AuditEntry |
    ae.accessType = ListAudit implies ae.userRole = HospitalAdministratorRole
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-011 Notes append-only
pred FR_011_NotesAppendOnly {
  all n: ClinicalNote | some ae: AuditEntry | ae.noteId = n.noteId
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-001 Authentication on all endpoints
pred FR_001_AuthRequired {
  all ae: AuditEntry | some u: User | u.userId = ae.userId
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-012 Every access is audited
pred FR_012_EveryAccessAudited {
  all n: ClinicalNote |
    some ae: AuditEntry | ae.noteId = n.noteId and ae.accessType = AddNote
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-006 Byte-equivalent 404 response
pred FR_006_ByteEquivalentResponse {
  some ae: AuditEntry |
    (ae.outcome = Denied or ae.outcome = NotFoundOrDenied) and
    (ae.accessType = ReadRecord or ae.accessType = AddNote)
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-014 Audit entries immutable
pred FR_014_AuditImmutable {
  all ae: AuditEntry | ae in AuditEntry
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-018 Administrator responses no clinical content
pred FR_018_AdminNoClinicaljContent {
  all ae: AuditEntry |
    ae.userRole = HospitalAdministratorRole implies (
      ae.accessType = ListAudit and ae.noteId = none
    )
}

// ===== Assertions =====

assert LeastPrivilege {
  LeastPrivilege
}

assert AppendOnly {
  AppendOnly
}

assert AuditCompleteness {
  AuditCompleteness
}

assert AttributionCorrectness {
  AttributionCorrectness
}

assert NoInformationLeakage {
  NoInformationLeakage
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

assert FR_004_CareTeamGating {
  FR_004_CareTeamGating
}

assert FR_005_AdminCannotReadClinicalContent {
  FR_005_AdminCannotReadClinicalContent
}

assert FR_017_AuditListAdminOnly {
  FR_017_AuditListAdminOnly
}

assert FR_011_NotesAppendOnly {
  FR_011_NotesAppendOnly
}

assert FR_001_AuthRequired {
  FR_001_AuthRequired
}

assert FR_012_EveryAccessAudited {
  FR_012_EveryAccessAudited
}

assert FR_006_ByteEquivalentResponse {
  FR_006_ByteEquivalentResponse
}

assert FR_014_AuditImmutable {
  FR_014_AuditImmutable
}

assert FR_018_AdminNoClinicaljContent {
  FR_018_AdminNoClinicaljContent
}

// ===== Checks =====

check LeastPrivilege for 5
check AppendOnly for 5
check AuditCompleteness for 5
check AttributionCorrectness for 5
check NoInformationLeakage for 5
check AuthRequiredEverywhere for 5
check FR_004_CareTeamGating for 5
check FR_005_AdminCannotReadClinicalContent for 5
check FR_017_AuditListAdminOnly for 5
check FR_011_NotesAppendOnly for 5
check FR_001_AuthRequired for 5
check FR_012_EveryAccessAudited for 5
check FR_006_ByteEquivalentResponse for 5
check FR_014_AuditImmutable for 5
check FR_018_AdminNoClinicaljContent for 5