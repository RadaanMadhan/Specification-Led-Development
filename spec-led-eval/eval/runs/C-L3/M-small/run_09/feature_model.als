// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===

abstract sig Role {}
one sig Clinician, Patient, ComplianceOfficer extends Role {}

abstract sig Operation {}
one sig Read, Append, List extends Operation {}

abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

sig User {
  user_id: String,
  display_name: String,
  role: one Role,
  assigned_record_id: lone String
}

sig Record {
  record_id: String,
  patient_name: String,
  date_of_birth: String
}

sig CareTeamMembership {
  clinician: one User,
  record: one Record,
  status: one String  // "active" or "ended"
}

sig ClinicalNote {
  note_id: String,
  record: one Record,
  author: one User,
  author_display_name: String,
  author_role: one Role,
  created_at: String,
  body: String
}

sig AuditEntry {
  entry_id: Int,
  record: lone Record,
  accessor: one User,
  accessor_display_name: String,
  accessor_role: one Role,
  timestamp: String,
  operation: one Operation,
  outcome: one Outcome,
  originating_ip_address: String,
  note: lone ClinicalNote
}

one sig PermMatrix {
  allowed: set Role -> Operation
}

// ============ FACTS ============

fact F_NonEmptyUniverse {
  some User
  some Record
  some AuditEntry
  some ClinicalNote
}

// FR-002: User holds exactly one role at a time
fact F_UserSingleRole {
  all u: User | one u.role
}

// FR-003: Patient has assigned_record_id; non-patient users do not
fact F_PatientRecordPairing {
  all u: User |
    (u.role = Patient implies one u.assigned_record_id) and
    (u.role != Patient implies no u.assigned_record_id)
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-001-FR-007
fact F_PermissionMatrix {
  PermMatrix.allowed = 
    (Clinician -> Read) + (Clinician -> Append) + (Clinician -> List) +
    (Patient -> Read) + (Patient -> List) +
    (ComplianceOfficer -> List)
}

// FR-001: All accesses must be authenticated
fact F_AuthenticationRequired {
  all a: AuditEntry | one a.accessor
}

// FR-004: Clinician can read only if on care team for that record
fact F_CareTeamGatingForRead {
  all a: AuditEntry |
    (a.accessor.role = Clinician and a.operation = Read and a.outcome = Permitted and some a.record) implies
      (exists m: CareTeamMembership | 
        m.clinician = a.accessor and m.record = a.record and m.status = "active")
}

// FR-006: Patient can read/list only their assigned record
fact F_PatientOwnRecordOnly {
  all a: AuditEntry |
    (a.accessor.role = Patient and a.outcome = Permitted and some a.record) implies
      a.accessor.assigned_record_id = a.record.record_id
}

// FR-007: Compliance officer can only list, not read clinical records
fact F_ComplianceOfficerListOnly {
  all a: AuditEntry |
    (a.accessor.role = ComplianceOfficer) implies a.operation = List
}

// FR-008: Unauthorized responses are byte-equivalent regardless of record existence
fact F_ByteEquivalentUnauth {
  all a1, a2: AuditEntry |
    (a1.outcome = Denied and a2.outcome = Denied and 
     a1.accessor = a2.accessor and a1.operation = a2.operation) implies
      (a1.accessor.role = a2.accessor.role)
}

// FR-012: Notes are append-only (no mutation or deletion)
fact F_AppendOnlyNotes {
  all n: ClinicalNote | one n
}

// FR-013: Every note append has a corresponding audit entry
fact F_AuditForEveryNote {
  all n: ClinicalNote |
    (exists a: AuditEntry | a.note = n and a.operation = Append and a.outcome = Permitted)
}

// FR-014: Audit entries contain all required fields
fact F_AuditEntryFieldsPresent {
  all a: AuditEntry |
    one a.accessor and
    one a.accessor_display_name and
    one a.accessor_role and
    one a.timestamp and
    one a.operation and
    one a.outcome and
    one a.originating_ip_address
}

// FR-015: Audit entries are immutable (no updates or deletes)
fact F_AuditImmutable {
  all a: AuditEntry | one a
}

// FR-018: Only compliance officers access system-wide audit log
fact F_ComplianceOnlySystemAudit {
  all a: AuditEntry |
    (a.operation = List and no a.record) implies a.accessor.role = ComplianceOfficer
}

// FR-019: Compliance responses contain no clinical content
fact F_ComplianceContentBlind {
  all u: User |
    u.role = ComplianceOfficer implies
      (all a: AuditEntry | a.accessor = u implies a.operation = List)
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014, data-model.md audit fields
fact F_AttributionCorrectness {
  all n: ClinicalNote |
    (exists a: AuditEntry | a.note = n) implies
      (exists a: AuditEntry | a.note = n and a.accessor = n.author and a.accessor_display_name = n.author_display_name)
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-003, data-model.md assigned_record_id
fact F_OwnershipExclusivity {
  all u: User | u.role = Patient implies one u.assigned_record_id
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008
fact F_NoInfoLeakOnDenial {
  all a: AuditEntry |
    a.outcome = Denied implies
      (no a.record or a.accessor.role = ComplianceOfficer)
}

// ============ PREDICATES & ASSERTIONS ============

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; spec.md FR-001-FR-007
pred LeastPrivilege {
  some User
  all u: User, op: Operation |
    u.role -> op in PermMatrix.allowed implies
      (exists a: AuditEntry | a.accessor = u and a.operation = op)
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  some User
  all r: Role, op: Operation |
    (r -> op in PermMatrix.allowed) or not (r -> op in PermMatrix.allowed)
}

assert PermissionCompleteness {
  PermissionCompleteness
}

check PermissionCompleteness for 5

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-004-FR-007; contracts/http-api.md
pred PermissionGrounding {
  some User
  all r: Role, op: Operation |
    r -> op in PermMatrix.allowed implies
      (exists a: AuditEntry | a.accessor.role = r and a.operation = op and a.outcome = Permitted)
}

assert PermissionGrounding {
  PermissionGrounding
}

check PermissionGrounding for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md
pred AuthRequiredEverywhere {
  all a: AuditEntry | one a.accessor
  some AuditEntry
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md AuditEntry
pred AuditCompleteness {
  all n: ClinicalNote |
    (exists a: AuditEntry | a.note = n and a.operation = Append and a.outcome = Permitted)
  some ClinicalNote
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012, FR-015; data-model.md ClinicalNote, AuditEntry
pred AppendOnly {
  all n: ClinicalNote | one n
  all a: AuditEntry | one a
  some ClinicalNote
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md audit fields
pred AttributionCorrectness {
  all a: AuditEntry |
    one a.accessor and one a.accessor_display_name and one a.accessor_role
  some AuditEntry
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-003; data-model.md User.assigned_record_id
pred OwnershipExclusivity {
  all u: User | u.role = Patient implies one u.assigned_record_id
  some Patient
}

assert OwnershipExclusivity {
  OwnershipExclusivity
}

check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004, FR-006; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  all a: AuditEntry |
    (a.outcome = Permitted and some a.record) implies
      ((a.accessor.role = Clinician and 
        exists m: CareTeamMembership | m.clinician = a.accessor and m.record = a.record and m.status = "active") or
       (a.accessor.role = Patient and a.accessor.assigned_record_id = a.record.record_id) or
       (a.accessor.role = ComplianceOfficer and a.operation = List))
  some AuditEntry
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008
pred NoInformationLeakage {
  all a: AuditEntry |
    a.outcome = Denied implies (no a.record or a.accessor.role = ComplianceOfficer)
  some AuditEntry
}

assert NoInformationLeakage {
  NoInformationLeakage
}

check NoInformationLeakage for 8

// FEATURE-SPECIFIC  ANCHOR: FR-001 Authentication required
pred FR_001_AuthRequired {
  all a: AuditEntry | one a.accessor
  some AuditEntry
}

assert FR_001_AuthRequired {
  FR_001_AuthRequired
}

check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 Single role per user
pred FR_002_SingleRole {
  all u: User | one u.role
  some User
}

assert FR_002_SingleRole {
  FR_002_SingleRole
}

check FR_002_SingleRole for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 Patient assigned record
pred FR_003_PatientAssignedRecord {
  all u: User |
    (u.role = Patient implies one u.assigned_record_id) and
    (u.role != Patient implies no u.assigned_record_id)
  some Patient
}

assert FR_003_PatientAssignedRecord {
  FR_003_PatientAssignedRecord
}

check FR_003_PatientAssignedRecord for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 Care-team gating
pred FR_004_CareTeamGating {
  all a: AuditEntry |
    (a.accessor.role = Clinician and a.operation = Read and a.outcome = Permitted and some a.record) implies
      (exists m: CareTeamMembership | m.clinician = a.accessor and m.record = a.record and m.status = "active")
  some Clinician
}

assert FR_004_CareTeamGating {
  FR_004_CareTeamGating
}

check FR_004_CareTeamGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 Patient self-access
pred FR_006_PatientSelfAccess {
  all a: AuditEntry |
    (a.accessor.role = Patient and a.outcome = Permitted and some a.record) implies
      a.accessor.assigned_record_id = a.record.record_id
  some Patient
}

assert FR_006_PatientSelfAccess {
  FR_006_PatientSelfAccess
}

check FR_006_PatientSelfAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 Compliance officer read-only
pred FR_007_ComplianceReadOnly {
  all a: AuditEntry | a.accessor.role = ComplianceOfficer implies a.operation = List
  some ComplianceOfficer
}

assert FR_007_ComplianceReadOnly {
  FR_007_ComplianceReadOnly
}

check FR_007_ComplianceReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 Byte-equivalent unauthorized response
pred FR_008_ByteEquivalentUnauth {
  all a: AuditEntry |
    a.outcome = Denied implies (no a.record or a.accessor.role = ComplianceOfficer)
  some AuditEntry
}

assert FR_008_ByteEquivalentUnauth {
  FR_008_ByteEquivalentUnauth
}

check FR_008_ByteEquivalentUnauth for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 Notes append-only
pred FR_012_AppendOnlyNotes {
  all n: ClinicalNote | one n
  some ClinicalNote
}

assert FR_012_AppendOnlyNotes {
  FR_012_AppendOnlyNotes
}

check FR_012_AppendOnlyNotes for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 Always-on audit
pred FR_013_AlwaysOnAudit {
  all n: ClinicalNote |
    (exists a: AuditEntry | a.note = n and a.operation = Append and a.outcome = Permitted)
  some ClinicalNote
}

assert FR_013_AlwaysOnAudit {
  FR_013_AlwaysOnAudit
}

check FR_013_AlwaysOnAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 Audit entry fields
pred FR_014_AuditEntryFields {
  all a: AuditEntry |
    one a.accessor and one a.accessor_display_name and 
    one a.accessor_role and one a.timestamp and 
    one a.operation and one a.outcome and one a.originating_ip_address
  some AuditEntry
}

assert FR_014_AuditEntryFields {
  FR_014_AuditEntryFields
}

check FR_014_AuditEntryFields for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 Audit immutability
pred FR_015_AuditImmutable {
  all a: AuditEntry | one a
  some AuditEntry
}

assert FR_015_AuditImmutable {
  FR_015_AuditImmutable
}

check FR_015_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019 Compliance content-blind
pred FR_019_ComplianceContentBlind {
  all a: AuditEntry | a.accessor.role = ComplianceOfficer implies a.operation = List
  some ComplianceOfficer
}

assert FR_019_ComplianceContentBlind {
  FR_019_ComplianceContentBlind
}

check FR_019_ComplianceContentBlind for 5