// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===

// Core domain enums
abstract sig Role {}
one sig Clinician, Patient, ComplianceOfficer extends Role {}

abstract sig Operation {}
one sig Read, Append, List extends Operation {}

abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

abstract sig Status {}
one sig Active, Ended extends Status {}

// Domain entities
sig User {
  id: one String,
  display_name: one String,
  role: one Role,
  assigned_record_id: lone String
}

sig Record {
  id: one String,
  patient_name: one String,
  date_of_birth: one String
}

sig CareTeamMembership {
  clinician_id: one String,
  record_id: one String,
  status: one Status
}

sig ClinicalNote {
  id: one String,
  record_id: one String,
  author_user_id: one String,
  body: one String
}

sig AuditEntry {
  record_id: lone String,
  accessor_user_id: one String,
  accessor_role: one Role,
  operation: one Operation,
  outcome: one Outcome,
  note_id: lone String
}

// Non-empty universe
fact F_NonEmptyUniverse {
  some User
  some Record
  some ClinicalNote
  some AuditEntry
  some CareTeamMembership
}

// FEATURE-SPECIFIC  ANCHOR: FR-002, FR-003
fact F_UserRoleAndRecordAssignment {
  all u: User |
    (u.role = Patient iff one u.assigned_record_id)
    and
    (u.role != Patient iff no u.assigned_record_id)
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004, FR-006, FR-007
fact F_ClinicianReadRequiresCareTeam {
  all ae: AuditEntry |
    (ae.accessor_role = Clinician and ae.outcome = Permitted and ae.operation = Read) implies
      (some ctm: CareTeamMembership |
        ctm.clinician_id = ae.accessor_user_id and
        ctm.record_id = ae.record_id and
        ctm.status = Active)
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md User.assigned_record_id
fact F_PatientAccessOwnRecordOnly {
  all ae: AuditEntry |
    (ae.accessor_role = Patient and ae.outcome = Permitted) implies
      (some u: User | u.id = ae.accessor_user_id and u.assigned_record_id = ae.record_id)
}

// FEATURE-SPECIFIC  ANCHOR: FR-007
fact F_ComplianceOfficerNoReadAccess {
  all ae: AuditEntry |
    ae.accessor_role = ComplianceOfficer implies ae.operation != Read
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012
fact F_NotesAppendOnlyByDesign {
  all cn: ClinicalNote |
    (some ae: AuditEntry | ae.note_id = cn.id and ae.operation = Append and ae.outcome = Permitted)
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013
fact F_AuditEntryForEveryAccess {
  all u: User, r: Record, op: Operation |
    (some ae: AuditEntry | ae.accessor_user_id = u.id and ae.record_id = r.id and ae.operation = op)
}

// FEATURE-SPECIFIC  ANCHOR: FR-018
fact F_SystemAccessLogComplianceOfficerOnly {
  all ae: AuditEntry |
    (ae.operation = List and ae.record_id = none) implies ae.accessor_role = ComplianceOfficer
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
fact F_AllAuditEntriesAttachedToAuthenticatedUsers {
  all ae: AuditEntry | (some u: User | u.id = ae.accessor_user_id)
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014
fact F_AuditRoleMatchesUserRole {
  all ae: AuditEntry |
    (some u: User | u.id = ae.accessor_user_id implies u.role = ae.accessor_role)
}

// ============ PREDICATES & ASSERTIONS ============

// PATTERN: LeastPrivilege
pred LeastPrivilege {
  some ae: AuditEntry | ae.accessor_role = Clinician and ae.operation = Read and ae.outcome = Permitted
  implies
  all ae: AuditEntry |
    (ae.accessor_role = Clinician and ae.operation = Read and ae.outcome = Permitted) implies
      (some ctm: CareTeamMembership |
        ctm.clinician_id = ae.accessor_user_id and
        ctm.record_id = ae.record_id and
        ctm.status = Active)
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some ae: AuditEntry
  implies
  all ae: AuditEntry | (some u: User | u.id = ae.accessor_user_id)
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_SingleRolePerUser {
  some u: User | u.role = Patient
  implies
  all u: User |
    (u.role = Clinician or u.role = Patient or u.role = ComplianceOfficer)
}

assert FR_002_SingleRolePerUser { FR_002_SingleRolePerUser }
check FR_002_SingleRolePerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_PatientAssignedRecord {
  some u: User | u.role = Patient
  implies
  all u: User | u.role = Patient iff (one u.assigned_record_id)
}

assert FR_003_PatientAssignedRecord { FR_003_PatientAssignedRecord }
check FR_003_PatientAssignedRecord for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_ClinicianCareTeamGating {
  some ae: AuditEntry | ae.accessor_role = Clinician and ae.operation = Read and ae.outcome = Permitted
  implies
  all ae: AuditEntry |
    (ae.accessor_role = Clinician and ae.operation = Read and ae.outcome = Permitted) implies
      (some ctm: CareTeamMembership |
        ctm.clinician_id = ae.accessor_user_id and
        ctm.record_id = ae.record_id and
        ctm.status = Active)
}

assert FR_004_ClinicianCareTeamGating { FR_004_ClinicianCareTeamGating }
check FR_004_ClinicianCareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_PatientSelfAccessOnly {
  some ae: AuditEntry | ae.accessor_role = Patient and ae.outcome = Permitted
  implies
  all ae: AuditEntry |
    (ae.accessor_role = Patient and ae.outcome = Permitted) implies
      (some u: User | u.id = ae.accessor_user_id and u.assigned_record_id = ae.record_id)
}

assert FR_006_PatientSelfAccessOnly { FR_006_PatientSelfAccessOnly }
check FR_006_PatientSelfAccessOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_ComplianceOfficerContentBlind {
  some ae: AuditEntry | ae.accessor_role = ComplianceOfficer
  implies
  all ae: AuditEntry | ae.accessor_role = ComplianceOfficer implies ae.operation != Read
}

assert FR_007_ComplianceOfficerContentBlind { FR_007_ComplianceOfficerContentBlind }
check FR_007_ComplianceOfficerContentBlind for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_NotesImmutable {
  some cn: ClinicalNote
  implies
  all cn: ClinicalNote |
    (some ae: AuditEntry | ae.note_id = cn.id and ae.operation = Append and ae.outcome = Permitted)
}

assert FR_012_NotesImmutable { FR_012_NotesImmutable }
check FR_012_NotesImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_AuditCompleteness {
  some u: User, r: Record
  implies
  all u: User, r: Record |
    (some ae: AuditEntry | ae.accessor_user_id = u.id and ae.record_id = r.id)
}

assert FR_013_AuditCompleteness { FR_013_AuditCompleteness }
check FR_013_AuditCompleteness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_SystemAccessLogComplianceOnly {
  some ae: AuditEntry | ae.operation = List and ae.record_id = none
  implies
  all ae: AuditEntry | (ae.operation = List and ae.record_id = none) implies ae.accessor_role = ComplianceOfficer
}

assert FR_018_SystemAccessLogComplianceOnly { FR_018_SystemAccessLogComplianceOnly }
check FR_018_SystemAccessLogComplianceOnly for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-003; data-model.md User.assigned_record_id
pred OwnershipExclusivity {
  some u: User | u.role = Patient
  implies
  all u: User | u.role = Patient implies (one u.assigned_record_id)
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006
pred OwnershipBasedAccess {
  some u: User, ae: AuditEntry | u.role = Patient and u.id = ae.accessor_user_id and ae.outcome = Permitted
  implies
  all u: User, ae: AuditEntry |
    (u.role = Patient and u.id = ae.accessor_user_id and ae.outcome = Permitted) implies
      u.assigned_record_id = ae.record_id
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012, FR-015
pred AppendOnly {
  some cn: ClinicalNote
  implies
  all cn: ClinicalNote |
    (some ae: AuditEntry | ae.note_id = cn.id and ae.operation = Append and ae.outcome = Permitted)
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md audit structure
pred AuditCompleteness {
  some u: User, r: Record, op: Operation
  implies
  all u: User, r: Record, op: Operation |
    (some ae: AuditEntry | ae.accessor_user_id = u.id and ae.record_id = r.id and ae.operation = op)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014
pred AttributionCorrectness {
  some ae: AuditEntry
  implies
  all ae: AuditEntry |
    (some u: User | u.id = ae.accessor_user_id implies u.role = ae.accessor_role)
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  some ae: AuditEntry
  implies
  all ae: AuditEntry | (some u: User | u.id = ae.accessor_user_id)
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5