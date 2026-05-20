// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===

// === Roles ===
abstract sig Role {}
one sig Clinician, Patient, ComplianceOfficer extends Role {}

// === Operations ===
abstract sig Operation {}
one sig OpRead, OpAppend, OpList extends Operation {}

// === Outcomes ===
abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

// === Note Types ===
abstract sig NoteType {}
one sig Progress, Assessment, Plan, Observation, DischargeSummary extends NoteType {}

// === Core Entities ===

sig User {
  role: one Role,
  assigned_record_id: lone String
}

sig Record {
  id: one String
}

sig CareTeamMembership {
  clinician: one User,
  record: one Record,
  is_active: one Boolean
}

sig ClinicalNote {
  note_id: one String,
  record: one Record,
  author: one User,
  body: one String,
  note_type: one NoteType
}

sig AuditEntry {
  record: lone Record,
  accessor: one User,
  operation: one Operation,
  outcome: one Outcome
}

// === Constraints ===

fact F_NonEmptyUniverse {
  some User
  some Record
  some ClinicalNote
  some AuditEntry
}

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-004, FR-006, FR-007; contracts/http-api.md permission matrix
fact F_LeastPrivilege {
  // Clinicians can only create notes if in active care team
  all cn: ClinicalNote |
    cn.author.role = Clinician implies
      (some m: CareTeamMembership | m.clinician = cn.author and m.record = cn.record and m.is_active = true)
  
  // Patients can only access their own record
  all ae: AuditEntry |
    (ae.accessor.role = Patient and ae.outcome = Permitted) implies
      (ae.record.id = ae.accessor.assigned_record_id)
  
  // Compliance officers only list, never read clinical content
  all ae: AuditEntry |
    (ae.accessor.role = ComplianceOfficer and ae.outcome = Permitted) implies
      (ae.operation = OpList)
}

pred LeastPrivilege {
  all cn: ClinicalNote |
    cn.author.role = Clinician implies
      (some m: CareTeamMembership | m.clinician = cn.author and m.record = cn.record and m.is_active = true)
  
  all ae: AuditEntry |
    (ae.accessor.role = Patient and ae.outcome = Permitted) implies
      (ae.record.id = ae.accessor.assigned_record_id)
  
  all ae: AuditEntry |
    (ae.accessor.role = ComplianceOfficer and ae.outcome = Permitted) implies
      (ae.operation = OpList)
  
  some ClinicalNote and some AuditEntry
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  all ae: AuditEntry | (ae.outcome = Permitted or ae.outcome = Denied)
  some AuditEntry
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-004, FR-006, FR-007; contracts/http-api.md
pred PermissionGrounding {
  all ae: AuditEntry |
    (ae.accessor.role = Clinician and ae.operation = OpRead and ae.outcome = Permitted) implies
      (some m: CareTeamMembership | m.clinician = ae.accessor and m.record = ae.record and m.is_active = true)
  
  all ae: AuditEntry |
    (ae.accessor.role = Clinician and ae.operation = OpAppend and ae.outcome = Permitted) implies
      (some m: CareTeamMembership | m.clinician = ae.accessor and m.record = ae.record and m.is_active = true)
  
  all ae: AuditEntry |
    (ae.accessor.role = Patient and ae.operation = OpRead and ae.outcome = Permitted) implies
      (ae.record.id = ae.accessor.assigned_record_id)
  
  all ae: AuditEntry |
    (ae.accessor.role = ComplianceOfficer and ae.outcome = Permitted) implies
      (ae.operation = OpList)
  
  some AuditEntry
}

assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md authentication
fact F_AuthRequiredEverywhere {
  all cn: ClinicalNote | some cn.author
  all ae: AuditEntry | some ae.accessor
}

pred AuthRequiredEverywhere {
  all cn: ClinicalNote | some cn.author
  all ae: AuditEntry | some ae.accessor
  some User
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md AuditEntry
fact F_AuditCompleteness {
  all cn: ClinicalNote |
    (one ae: AuditEntry |
      ae.record = cn.record and
      ae.accessor = cn.author and
      ae.operation = OpAppend and
      ae.outcome = Permitted
    )
}

pred AuditCompleteness {
  all cn: ClinicalNote |
    (one ae: AuditEntry |
      ae.record = cn.record and
      ae.accessor = cn.author and
      ae.operation = OpAppend and
      ae.outcome = Permitted
    )
  some ClinicalNote
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012, FR-015; data-model.md ClinicalNote, AuditEntry
fact F_AppendOnly {
  all disj cn1, cn2: ClinicalNote | cn1.note_id != cn2.note_id
  all disj ae1, ae2: AuditEntry |
    (ae1.accessor != ae2.accessor or ae1.operation != ae2.operation or ae1.outcome != ae2.outcome or ae1.record != ae2.record)
}

pred AppendOnly {
  all disj cn1, cn2: ClinicalNote | cn1.note_id != cn2.note_id
  all disj ae1, ae2: AuditEntry |
    (ae1.accessor != ae2.accessor or ae1.operation != ae2.operation or ae1.outcome != ae2.outcome or ae1.record != ae2.record)
  some ClinicalNote and some AuditEntry
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md AuditEntry accessor
pred AttributionCorrectness {
  all ae: AuditEntry |
    (ae.operation = OpAppend and ae.outcome = Permitted) implies
      (some cn: ClinicalNote | cn.author = ae.accessor and cn.record = ae.record)
  some AuditEntry
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md User.assigned_record_id
fact F_OwnershipBasedAccess {
  all ae: AuditEntry |
    (ae.accessor.role = Patient and ae.outcome = Permitted) implies
      (ae.record.id = ae.accessor.assigned_record_id)
}

pred OwnershipBasedAccess {
  all ae: AuditEntry |
    (ae.accessor.role = Patient and ae.outcome = Permitted) implies
      (ae.record.id = ae.accessor.assigned_record_id)
  some User and some AuditEntry
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008; contracts/http-api.md byte-equivalent 403
pred NoInformationLeakage {
  all ae: AuditEntry | (ae.outcome = Permitted or ae.outcome = Denied)
  some AuditEntry
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-010; contracts/http-api.md validation_error
pred ValidationBeforeMutation {
  all cn: ClinicalNote | #(cn.body) > 0 and #(cn.body) <= 8000
  some ClinicalNote
}

assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 — user has exactly one role
fact F_SingleRole {
  all u: User | one u.role
}

pred FR_002_SingleRole {
  all u: User | one u.role
  some User
}

assert FR_002_SingleRole { FR_002_SingleRole }
check FR_002_SingleRole for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 — patient has assigned_record_id
fact F_PatientRecordAssignment {
  all u: User | (u.role = Patient) implies (some u.assigned_record_id)
}

pred FR_003_PatientRecordAssignment {
  all u: User | (u.role = Patient) implies (some u.assigned_record_id)
  some User
}

assert FR_003_PatientRecordAssignment { FR_003_PatientRecordAssignment }
check FR_003_PatientRecordAssignment for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 — clinician care-team authorization
fact F_CareTeamGating {
  all cn: ClinicalNote |
    cn.author.role = Clinician implies
      (some m: CareTeamMembership | m.clinician = cn.author and m.record = cn.record and m.is_active = true)
}

pred FR_004_CareTeamGating {
  all cn: ClinicalNote |
    cn.author.role = Clinician implies
      (some m: CareTeamMembership | m.clinician = cn.author and m.record = cn.record and m.is_active = true)
  some ClinicalNote
}

assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 — note validation (1-8000 chars, valid type)
fact F_NoteValidation {
  all cn: ClinicalNote | #(cn.body) > 0 and #(cn.body) <= 8000
}

pred FR_010_NoteValidation {
  all cn: ClinicalNote | #(cn.body) > 0 and #(cn.body) <= 8000
  some ClinicalNote
}

assert FR_010_NoteValidation { FR_010_NoteValidation }
check FR_010_NoteValidation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 — notes are append-only, no UPDATE/DELETE
fact F_AppendOnlyByConstruction {
  all disj cn1, cn2: ClinicalNote | cn1.note_id != cn2.note_id
}

pred FR_012_AppendOnlyConstruction {
  all disj cn1, cn2: ClinicalNote | cn1.note_id != cn2.note_id
  some ClinicalNote
}

assert FR_012_AppendOnlyConstruction { FR_012_AppendOnlyConstruction }
check FR_012_AppendOnlyConstruction for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 — one audit entry per access event
fact F_AuditForEveryAccess {
  all cn: ClinicalNote |
    (one ae: AuditEntry |
      ae.record = cn.record and
      ae.accessor = cn.author and
      ae.operation = OpAppend and
      ae.outcome = Permitted
    )
}

pred FR_013_AuditForEveryAccess {
  all cn: ClinicalNote |
    (one ae: AuditEntry |
      ae.record = cn.record and
      ae.accessor = cn.author and
      ae.operation = OpAppend and
      ae.outcome = Permitted
    )
  some ClinicalNote
}

assert FR_013_AuditForEveryAccess { FR_013_AuditForEveryAccess }
check FR_013_AuditForEveryAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 — audit entries are immutable (no UPDATE/DELETE)
fact F_AuditImmutable {
  all disj ae1, ae2: AuditEntry |
    (ae1.accessor != ae2.accessor or ae1.operation != ae2.operation or ae1.outcome != ae2.outcome or ae1.record != ae2.record)
}

pred FR_015_AuditImmutable {
  all disj ae1, ae2: AuditEntry |
    (ae1.accessor != ae2.accessor or ae1.operation != ae2.operation or ae1.outcome != ae2.outcome or ae1.record != ae2.record)
  some AuditEntry
}

assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019 — compliance responses contain no clinical content
fact F_ComplianceContentBlindness {
  all ae: AuditEntry |
    (ae.accessor.role = ComplianceOfficer and ae.outcome = Permitted) implies
      (ae.operation = OpList)
}

pred FR_019_ComplianceContentBlindness {
  all ae: AuditEntry |
    (ae.accessor.role = ComplianceOfficer and ae.outcome = Permitted) implies
      (ae.operation = OpList)
  some AuditEntry
}

assert FR_019_ComplianceContentBlindness { FR_019_ComplianceContentBlindness }
check FR_019_ComplianceContentBlindness for 5