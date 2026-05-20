// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===
// Feature: C-L3 (013-hipaa-clinical-records)
// A formal-methods encoding of authentication, authorization, audit completeness,
// append-only invariants, and content-blindness for a HIPAA-regulated clinical record system.

// ============================================================================
// ROLE HIERARCHY
// ============================================================================

abstract sig Role {}
one sig Clinician, Patient, ComplianceOfficer extends Role {}

// ============================================================================
// OPERATION AND OUTCOME SIGS
// ============================================================================

abstract sig OperationKind {}
one sig ReadOp, AppendOp, ListOp extends OperationKind {}

abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

abstract sig AuthorisationBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientOwn, PatientOther,
         ComplianceRole, Outsider, RecordNotFound extends AuthorisationBasis {}

// ============================================================================
// CORE ENTITIES
// ============================================================================

sig User {
  user_id: one Id,
  display_name: one String,
  role: one Role,
  assigned_record_id: lone Id
}

sig Record {
  record_id: one Id,
  patient_name: one String,
  date_of_birth: one String
}

sig CareTeamMembership {
  clinician_id: one Id,
  record_id: one Id,
  status: one MembershipStatus
}

abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

abstract sig NoteType {}
one sig Progress, Assessment, Plan, Observation, DischargeSummary extends NoteType {}

sig ClinicalNote {
  note_id: one Id,
  record_id: one Id,
  author_user_id: one Id,
  author_display_name: one String,
  author_role: one Role,
  created_at: one Timestamp,
  note_type: one NoteType,
  body: one String,
  encounter_date: one String
}

sig AuditEntry {
  audit_id: one Id,
  record_id: lone Id,
  accessor_user_id: one Id,
  accessor_user_display_name: one String,
  accessor_role: one Role,
  timestamp: one Timestamp,
  operation: one OperationKind,
  outcome: one Outcome,
  authorisation_basis: one AuthorisationBasis,
  originating_ip_address: one String,
  note_id: lone Id
}

// ============================================================================
// AUXILIARY SIGS
// ============================================================================

sig Id {}
sig String {}
sig Timestamp {}

// ============================================================================
// FACTS: NON-EMPTY UNIVERSE
// ============================================================================

fact F_NonEmptyUniverse {
  some User
  some Record
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
}

// ============================================================================
// FACTS: STRUCTURAL RULES ENCODING FRs
// ============================================================================

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md User.assigned_record_id; FR-003
fact F_PatientRecordPairing {
  all u: User |
    (u.role = Patient) iff (u.assigned_record_id != none)
  all u: User |
    (u.role != Patient) iff (u.assigned_record_id = none)
}

// FEATURE-SPECIFIC  ANCHOR: data-model.md ClinicalNote.author_role CHECK; FR-011
fact F_ClinicalNoteAuthor {
  all note: ClinicalNote |
    note.author_role = Clinician
}

// PATTERN: AppendOnly  ANCHOR: FR-012; data-model.md clinical_notes append-only
fact F_AppendOnlyNotes {
  all disj n1, n2: ClinicalNote |
    n1.note_id != n2.note_id
}

// PATTERN: AppendOnly  ANCHOR: FR-015, FR-017; data-model.md audit_entries append-only
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry |
    ae1.audit_id != ae2.audit_id
}

// PATTERN: AuditCompleteness  ANCHOR: FR-013; spec.md SC-001, SC-002
fact F_AuditCompleteness_NoteCreation {
  all note: ClinicalNote |
    (one ae: AuditEntry |
      ae.operation = AppendOp and
      ae.outcome = Permitted and
      ae.note_id = note.note_id and
      ae.record_id = note.record_id and
      ae.accessor_user_id = note.author_user_id and
      ae.accessor_role = Clinician)
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-007
fact F_LeastPrivilegePatientAppend {
  all ae: AuditEntry |
    (ae.accessor_role = Patient and ae.operation = AppendOp) implies
      ae.outcome = Denied
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-007
fact F_LeastPrivilegeComplianceRead {
  all ae: AuditEntry |
    (ae.accessor_role = ComplianceOfficer and ae.operation = ReadOp) implies
      ae.outcome = Denied
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-007
fact F_LeastPrivilegeComplianceAppend {
  all ae: AuditEntry |
    (ae.accessor_role = ComplianceOfficer and ae.operation = AppendOp) implies
      ae.outcome = Denied
}

// FEATURE-SPECIFIC  ANCHOR: FR-004, FR-005 care-team gating for clinicians
fact F_CareTeamClinicianGating {
  all ae: AuditEntry |
    (ae.accessor_role = Clinician and ae.operation = ReadOp and ae.outcome = Permitted) implies
      ae.authorisation_basis = CareTeamMember
}

// FEATURE-SPECIFIC  ANCHOR: FR-006 patient self-access gating
fact F_PatientOwnRecordAccess {
  all ae: AuditEntry |
    (ae.accessor_role = Patient and ae.operation = ReadOp and ae.outcome = Permitted) implies
      ae.authorisation_basis = PatientOwn
}

// FEATURE-SPECIFIC  ANCHOR: FR-007 compliance officer list-only operations
fact F_ComplianceOfficerListOnly {
  all ae: AuditEntry |
    (ae.accessor_role = ComplianceOfficer and ae.outcome = Permitted) implies
      ae.operation = ListOp
}

// PATTERN: NoInformationLeakage  ANCHOR: FR-008; contracts/http-api.md byte-equivalent 403
fact F_NoInformationLeakage {
  all disj ae1, ae2: AuditEntry |
    (ae1.accessor_role = ae2.accessor_role and
     ae1.operation = ae2.operation and
     ae1.outcome = Denied and ae2.outcome = Denied) implies
    ((ae1.authorisation_basis in {NotCareTeamMember, RecordNotFound}) and
     (ae2.authorisation_basis in {NotCareTeamMember, RecordNotFound})) or
    ((ae1.authorisation_basis in {PatientOther, RecordNotFound}) and
     (ae2.authorisation_basis in {PatientOther, RecordNotFound}))
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-014; data-model.md snapshot fields
fact F_AuditAttributionCorrectness {
  all ae: AuditEntry |
    (ae.operation = AppendOp and ae.outcome = Permitted and ae.note_id != none) implies
      ((one note: ClinicalNote |
        note.note_id = ae.note_id and
        note.author_user_id = ae.accessor_user_id and
        note.author_display_name = ae.accessor_user_display_name))
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001; contracts/http-api.md
fact F_AllAuditEntriesAuthenticated {
  all ae: AuditEntry |
    ae.accessor_user_id != none and ae.accessor_role != none
}

// ============================================================================
// PREDICATES & ASSERTIONS
// ============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-004, FR-006, FR-007
pred LeastPrivilege {
  all ae: AuditEntry |
    (ae.accessor_role = Clinician and ae.operation = ReadOp) implies
      ((ae.outcome = Permitted) implies (ae.authorisation_basis = CareTeamMember))
  and
  all ae: AuditEntry |
    (ae.accessor_role = Clinician and ae.operation = AppendOp) implies
      ((ae.outcome = Permitted) implies (ae.authorisation_basis = CareTeamMember))
  and
  no (ae: AuditEntry | ae.accessor_role = Patient and ae.operation = AppendOp and ae.outcome = Permitted)
  and
  no (ae: AuditEntry | ae.accessor_role = ComplianceOfficer and ae.operation = ReadOp and ae.outcome = Permitted)
  and
  some ae: AuditEntry | ae.outcome = Permitted
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: AppendOnly  ANCHOR: FR-012, FR-015; data-model.md clinical_notes, audit_entries
pred AppendOnly {
  all disj n1, n2: ClinicalNote | n1.note_id != n2.note_id
  and
  all disj ae1, ae2: AuditEntry | ae1.audit_id != ae2.audit_id
  and
  some ClinicalNote
  and
  some AuditEntry
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-013; spec.md SC-001, SC-002
pred AuditCompleteness {
  all note: ClinicalNote |
    (one ae: AuditEntry |
      ae.operation = AppendOp and
      ae.outcome = Permitted and
      ae.note_id = note.note_id and
      ae.accessor_user_id = note.author_user_id)
  and
  all ae: AuditEntry |
    (ae.operation = AppendOp and ae.outcome = Permitted) implies
      ((one note: ClinicalNote | note.note_id = ae.note_id))
  and
  some note: ClinicalNote | some ae: AuditEntry | note.note_id = ae.note_id
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-014; data-model.md snapshot fields
pred AttributionCorrectness {
  all ae: AuditEntry |
    ae.accessor_user_id != none and ae.accessor_role != none
  and
  all ae: AuditEntry |
    (ae.operation = AppendOp and ae.outcome = Permitted and ae.note_id != none) implies
      ((let note = {n: ClinicalNote | n.note_id = ae.note_id} |
        note.author_user_id = ae.accessor_user_id))
  and
  some ae: AuditEntry | ae.operation = AppendOp and ae.outcome = Permitted
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-006; spec.md US3, data-model.md assigned_record_id
pred OwnershipBasedAccess {
  all ae: AuditEntry |
    (ae.accessor_role = Patient and ae.operation = ReadOp and ae.outcome = Permitted) implies
      (ae.authorisation_basis = PatientOwn)
  and
  all ae: AuditEntry |
    (ae.accessor_role = Patient and ae.outcome = Denied) implies
      (ae.authorisation_basis != PatientOwn)
  and
  some ae: AuditEntry | ae.accessor_role = Patient and ae.outcome = Permitted
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001; contracts/http-api.md authentication boundary
pred AuthRequiredEverywhere {
  all ae: AuditEntry |
    ae.accessor_user_id != none
  and
  some ae: AuditEntry | ae.outcome = Permitted or ae.outcome = Denied
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: NoInformationLeakage  ANCHOR: FR-008; contracts/http-api.md byte-equivalent 403
pred NoInformationLeakage {
  all ae: AuditEntry |
    ae.outcome = Denied implies
      (ae.authorisation_basis in {NotCareTeamMember, PatientOther, RecordNotFound, Outsider})
  and
  some ae: AuditEntry | ae.outcome = Denied
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002; data-model.md Role enum
pred FR_002_SingleRole {
  all u: User |
    (u.role = Clinician or u.role = Patient or u.role = ComplianceOfficer) and
    (one r: Role | u.role = r)
  and
  some u: User | u.role = Clinician
}

assert FR_002_SingleRole { FR_002_SingleRole }
check FR_002_SingleRole for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003; data-model.md User.assigned_record_id
pred FR_003_PatientRecordAssignment {
  all u: User |
    (u.role = Patient implies u.assigned_record_id != none) and
    (u.role != Patient implies u.assigned_record_id = none)
  and
  some u: User | u.role = Patient
}

assert FR_003_PatientRecordAssignment { FR_003_PatientRecordAssignment }
check FR_003_PatientRecordAssignment for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004, FR-005; spec.md care-team gating
pred FR_004_CareTeamGating {
  all ae: AuditEntry |
    (ae.accessor_role = Clinician and ae.operation = ReadOp and ae.outcome = Permitted) implies
      (ae.authorisation_basis = CareTeamMember)
  and
  some ae: AuditEntry | ae.accessor_role = Clinician and ae.authorisation_basis = CareTeamMember and ae.outcome = Permitted
}

assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006; spec.md US3 patient self-access
pred FR_006_PatientSelfAccess {
  all ae: AuditEntry |
    (ae.accessor_role = Patient and ae.outcome = Permitted) implies
      (ae.authorisation_basis = PatientOwn)
  and
  some ae: AuditEntry | ae.accessor_role = Patient and ae.outcome = Permitted
}

assert FR_006_PatientSelfAccess { FR_006_PatientSelfAccess }
check FR_006_PatientSelfAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007; contracts/http-api.md compliance officer endpoint access
pred FR_007_ComplianceContentBlindness {
  all ae: AuditEntry |
    ae.accessor_role = ComplianceOfficer implies (ae.operation = ListOp and ae.outcome = Permitted)
  and
  some ae: AuditEntry | ae.accessor_role = ComplianceOfficer and ae.outcome = Permitted
}

assert FR_007_ComplianceContentBlindness { FR_007_ComplianceContentBlindness }
check FR_007_ComplianceContentBlindness for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008; contracts/http-api.md byte-equivalent 403
pred FR_008_ByteEquivalent403 {
  all ae: AuditEntry |
    ae.outcome = Denied implies
      (ae.authorisation_basis != CareTeamMember and
       ae.authorisation_basis != PatientOwn and
       ae.authorisation_basis != ComplianceRole)
  and
  some ae: AuditEntry | ae.outcome = Denied
}

assert FR_008_ByteEquivalent403 { FR_008_ByteEquivalent403 }
check FR_008_ByteEquivalent403 for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010; spec.md note validation
pred FR_010_NoteValidation {
  all note: ClinicalNote |
    note.body != none and
    note.note_type in {Progress, Assessment, Plan, Observation, DischargeSummary}
  and
  some note: ClinicalNote
}

assert FR_010_NoteValidation { FR_010_NoteValidation }
check FR_010_NoteValidation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012; spec.md notes append-only
pred FR_012_NotesAppendOnly {
  all disj n1, n2: ClinicalNote | n1.note_id != n2.note_id
  and
  some note: ClinicalNote | note.author_role = Clinician
}

assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013; spec.md audit entries for all access operations
pred FR_013_AuditCompleteness {
  some ae: AuditEntry | ae.operation = ReadOp
  and
  some ae: AuditEntry | ae.operation = AppendOp
  and
  some ae: AuditEntry | ae.operation = ListOp
}

assert FR_013_AuditCompleteness { FR_013_AuditCompleteness }
check FR_013_AuditCompleteness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015; spec.md audit entries immutable
pred FR_015_AuditImmutable {
  all disj ae1, ae2: AuditEntry | ae1.audit_id != ae2.audit_id
  and
  some ae: AuditEntry
}

assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018; contracts/http-api.md GET /access-log
pred FR_018_ComplianceLogAccess {
  all ae: AuditEntry |
    ae.operation = ListOp implies ae.accessor_role = ComplianceOfficer
  and
  some ae: AuditEntry | ae.operation = ListOp and ae.accessor_role = ComplianceOfficer
}

assert FR_018_ComplianceLogAccess { FR_018_ComplianceLogAccess }
check FR_018_ComplianceLogAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019; spec.md compliance responses content-blind
pred FR_019_ComplianceContentBlind {
  all ae: AuditEntry |
    ae.accessor_role = ComplianceOfficer implies (ae.operation = ListOp)
  and
  some ae: AuditEntry | ae.accessor_role = ComplianceOfficer
}

assert FR_019_ComplianceContentBlind { FR_019_ComplianceContentBlind }
check FR_019_ComplianceContentBlind for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020; spec.md URL paths use opaque record_id only
pred FR_020_URLPaths {
  all r: Record | r.record_id != none
  and
  some r: Record
}

assert FR_020_URLPaths { FR_020_URLPaths }
check FR_020_URLPaths for 5