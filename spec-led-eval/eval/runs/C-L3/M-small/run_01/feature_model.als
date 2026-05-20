// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===

// Dynamic sigs
sig User {
  user_id: one String,
  display_name: one String,
  role: one Role,
  assigned_record_id: lone String
}

sig Record {
  record_id: one String,
  patient_name: one String,
  date_of_birth: one String
}

sig CareTeamMembership {
  clinician_user_id: one String,
  record_id: one String,
  status: one MembershipStatus
}

sig ClinicalNote {
  note_id: one String,
  record_id: one String,
  author_user_id: one String,
  created_at: one String,
  note_type: one NoteType,
  body: one String
}

sig AuditEntry {
  entry_id: one Int,
  record_id: lone String,
  accessor_user_id: one String,
  timestamp: one String,
  operation: one Operation,
  outcome: one Outcome,
  authorisation_basis: one AuthorisationBasis,
  originating_ip: one String,
  note_id_created: lone String
}

sig AccessEvent {
  accessor: one User,
  record: lone Record,
  operation: one Operation,
  outcome: one Outcome
}

// Static sigs
abstract sig Role {}
one sig ClinicianRole extends Role {}
one sig PatientRole extends Role {}
one sig ComplianceOfficerRole extends Role {}

abstract sig Operation {}
one sig ReadOp extends Operation {}
one sig AppendOp extends Operation {}
one sig ListOp extends Operation {}

abstract sig Outcome {}
one sig PermittedOutcome extends Outcome {}
one sig DeniedOutcome extends Outcome {}

abstract sig AuthorisationBasis {}
one sig CareTeamMemberBasis extends AuthorisationBasis {}
one sig NotCareTeamMemberBasis extends AuthorisationBasis {}
one sig PatientOwnBasis extends AuthorisationBasis {}
one sig PatientOtherBasis extends AuthorisationBasis {}
one sig ComplianceRoleBasis extends AuthorisationBasis {}

abstract sig MembershipStatus {}
one sig ActiveStatus extends MembershipStatus {}
one sig EndedStatus extends MembershipStatus {}

abstract sig NoteType {}
one sig ProgressNote extends NoteType {}
one sig AssessmentNote extends NoteType {}
one sig PlanNote extends NoteType {}
one sig ObservationNote extends NoteType {}
one sig DischargeSummaryNote extends NoteType {}

sig String {}
sig Int {}

fact F_NonEmptyUniverse {
  some User
  some Record
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
  some AccessEvent
}

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-004–007; contracts/http-api.md permission matrix
pred LeastPrivilege {
  all ae: AccessEvent |
    (ae.outcome = PermittedOutcome) implies (
      (ae.accessor.role = ClinicianRole && ae.operation = ReadOp) implies
        (some m: CareTeamMembership |
          m.clinician_user_id = ae.accessor.user_id &&
          m.record_id = ae.record.record_id &&
          m.status = ActiveStatus
        )
    ) &&
    (ae.outcome = PermittedOutcome) implies (
      (ae.accessor.role = ClinicianRole && ae.operation = AppendOp) implies
        (some m: CareTeamMembership |
          m.clinician_user_id = ae.accessor.user_id &&
          m.record_id = ae.record.record_id &&
          m.status = ActiveStatus
        )
    ) &&
    (ae.outcome = PermittedOutcome) implies (
      (ae.accessor.role = PatientRole && ae.operation = ReadOp) implies
        (ae.accessor.assigned_record_id = ae.record.record_id)
    ) &&
    (ae.outcome = PermittedOutcome) implies (
      (ae.accessor.role = ComplianceOfficerRole && ae.operation = ReadOp) implies false
    )
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  all ae: AccessEvent |
    (ae.outcome = PermittedOutcome) || (ae.outcome = DeniedOutcome)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all ae: AccessEvent |
    (some u: User | ae.accessor = u)
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md constraints
pred AuditCompleteness {
  all ae: AccessEvent |
    (one aud: AuditEntry |
      aud.accessor_user_id = ae.accessor.user_id &&
      aud.operation = ae.operation &&
      aud.outcome = ae.outcome &&
      ((ae.record = none) implies (aud.record_id = none) else (aud.record_id = ae.record.record_id))
    )
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012, FR-015; data-model.md no UPDATE/DELETE
pred AppendOnly {
  all n1, n2: ClinicalNote |
    (n1.note_id = n2.note_id) implies n1 = n2
}

assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md audit-entry fields
pred AttributionCorrectness {
  all aud: AuditEntry, u: User |
    (aud.accessor_user_id = u.user_id && aud.outcome = PermittedOutcome && aud.operation = AppendOp) implies
      (u.role = ClinicianRole)
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008
pred NoInformationLeakage {
  all u: User, r: Record |
    (all ae: AccessEvent |
      ((ae.accessor = u && ae.operation = ReadOp && ae.outcome = DeniedOutcome)) implies
        (ae.record = r)  // All denied reads have consistent reason
    )
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 Care-Team Membership Gating
pred FR_004_CareTeamGating {
  all u: User, r: Record |
    (u.role = ClinicianRole) implies (
      all ae: AccessEvent |
        ((ae.accessor = u && ae.record = r && (ae.operation = ReadOp || ae.operation = AppendOp)) &&
         ae.outcome = PermittedOutcome) implies
          (some m: CareTeamMembership |
            m.clinician_user_id = u.user_id &&
            m.record_id = r.record_id &&
            m.status = ActiveStatus
          )
    )
}

assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 Patient Can Only Read Own Record
pred FR_006_PatientSelfAccess {
  all u: User |
    (u.role = PatientRole) implies (
      all ae: AccessEvent |
        ((ae.accessor = u && ae.operation = ReadOp && ae.outcome = PermittedOutcome)) implies
          (ae.record.record_id = u.assigned_record_id)
    )
}

assert FR_006_PatientSelfAccess { FR_006_PatientSelfAccess }
check FR_006_PatientSelfAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 Compliance Officer Cannot Read Clinical Records
pred FR_007_ComplianceNoRecordRead {
  all u: User |
    (u.role = ComplianceOfficerRole) implies (
      all ae: AccessEvent |
        ((ae.accessor = u && ae.operation = ReadOp)) implies
          (ae.outcome = DeniedOutcome)
    )
}

assert FR_007_ComplianceNoRecordRead { FR_007_ComplianceNoRecordRead }
check FR_007_ComplianceNoRecordRead for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 Notes Are Append-Only (No Update/Delete)
pred FR_012_NotesAppendOnly {
  all n: ClinicalNote |
    (all n2: ClinicalNote |
      (n.note_id = n2.note_id) implies n = n2
    )
}

assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 One Audit Entry Per Access Event
pred FR_013_OneAuditPerAccess {
  all ae: AccessEvent |
    (one aud: AuditEntry |
      aud.accessor_user_id = ae.accessor.user_id &&
      aud.operation = ae.operation &&
      aud.outcome = ae.outcome
    )
}

assert FR_013_OneAuditPerAccess { FR_013_OneAuditPerAccess }
check FR_013_OneAuditPerAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 Audit Entries Are Immutable (No Update/Delete)
pred FR_015_AuditImmutable {
  all a: AuditEntry |
    (all a2: AuditEntry |
      (a.entry_id = a2.entry_id) implies a = a2
    )
}

assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-001 All Access Must Be Authenticated
pred FR_001_AuthRequired {
  all ae: AccessEvent |
    (some u: User | ae.accessor = u)
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 Single Role Per User
pred FR_002_OneRolePerUser {
  all u: User |
    ((u.role = ClinicianRole) || (u.role = PatientRole) || (u.role = ComplianceOfficerRole))
}

assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 Patient Has Exactly One Assigned Record
pred FR_003_PatientAssignedRecord {
  all u: User |
    ((u.role = PatientRole) implies (u.assigned_record_id != none)) &&
    ((u.role != PatientRole) implies (u.assigned_record_id = none))
}

assert FR_003_PatientAssignedRecord { FR_003_PatientAssignedRecord }
check FR_003_PatientAssignedRecord for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 200ms Latency SLA for Non-Care-Team Clinician Denials
pred FR_009_LatencySLA {
  all u: User, r: Record |
    (u.role = ClinicianRole && (no m: CareTeamMembership |
      m.clinician_user_id = u.user_id && m.record_id = r.record_id && m.status = ActiveStatus)) implies (
      all ae: AccessEvent |
        ((ae.accessor = u && ae.record = r && ae.operation = ReadOp)) implies
          (ae.outcome = DeniedOutcome)
    )
}

assert FR_009_LatencySLA { FR_009_LatencySLA }
check FR_009_LatencySLA for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 Compliance Responses Contain No Clinical Content
pred FR_019_ComplianceContentBlind {
  all u: User |
    (u.role = ComplianceOfficerRole) implies (
      all aud: AuditEntry |
        ((aud.accessor_user_id = u.user_id && aud.operation = ListOp && aud.outcome = PermittedOutcome)) implies
          (all n: ClinicalNote | n.note_id = aud.note_id_created implies n.body != aud.note_id_created)
    )
}

assert FR_019_ComplianceContentBlind { FR_019_ComplianceContentBlind }
check FR_019_ComplianceContentBlind for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020 No PII (Patient Demographics) in URL Paths
pred FR_020_NoPIIInURLPaths {
  all r: Record |
    (r.record_id != r.patient_name) &&
    (r.record_id != r.date_of_birth)
}

assert FR_020_NoPIIInURLPaths { FR_020_NoPIIInURLPaths }
check FR_020_NoPIIInURLPaths for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 Clinician Cannot Access System-Wide Audit Log
pred FR_005_ClinicianNoSystemAudit {
  all u: User |
    (u.role = ClinicianRole) implies (
      all ae: AccessEvent |
        ((ae.accessor = u && ae.record = none && ae.operation = ListOp)) implies
          (ae.outcome = DeniedOutcome)
    )
}

assert FR_005_ClinicianNoSystemAudit { FR_005_ClinicianNoSystemAudit }
check FR_005_ClinicianNoSystemAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 Note Submission Validation
pred FR_010_NoteValidation {
  all n: ClinicalNote |
    (n.body != "") &&
    (n.note_type = ProgressNote || n.note_type = AssessmentNote || 
     n.note_type = PlanNote || n.note_type = ObservationNote ||
     n.note_type = DischargeSummaryNote)
}

assert FR_010_NoteValidation { FR_010_NoteValidation }
check FR_010_NoteValidation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 Appended Notes Persist Correctly
pred FR_011_NotePersistence {
  all ae: AccessEvent |
    ((ae.accessor.role = ClinicianRole && ae.operation = AppendOp && ae.outcome = PermittedOutcome)) implies
      (some n: ClinicalNote |
        n.record_id = ae.record.record_id &&
        n.author_user_id = ae.accessor.user_id
      )
}

assert FR_011_NotePersistence { FR_011_NotePersistence }
check FR_011_NotePersistence for 8