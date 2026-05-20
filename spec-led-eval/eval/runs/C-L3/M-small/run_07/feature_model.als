// === feature_model.als — Alloy model for C-L3 HIPAA Clinical Record Access ===

// === Core Domain Sigs ===

abstract sig Role {}
one sig Clinician, Patient, ComplianceOfficer extends Role {}

sig User {
  user_id: one String,
  display_name: one String,
  role: one Role,
  assigned_record_id: lone String
}

sig Record {
  record_id: one String
}

abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

sig CareTeamMembership {
  clinician: one User,
  record: one Record,
  episode_of_care_id: one String,
  status: one MembershipStatus
}

abstract sig NoteType {}
one sig Progress, Assessment, Plan, Observation, DischargeSummary extends NoteType {}

sig ClinicalNote {
  note_id: one String,
  record: one Record,
  author_user_id: one String,
  author_display_name: one String,
  created_at: one String,
  note_type: one NoteType,
  body: one String
}

abstract sig Operation {}
one sig ReadOp, AppendOp, ListOp extends Operation {}

abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

sig AuditEntry {
  entry_id: one Int,
  record_id: lone String,
  accessor_user_id: one String,
  accessor_user_display_name: one String,
  accessor_role: one Role,
  timestamp: one String,
  operation: one Operation,
  outcome: one Outcome,
  originating_ip_address: one String,
  note_id: lone String
}

// === Non-empty Universe ===

fact F_NonEmptyUniverse {
  some User
  some Record
  some ClinicalNote
  some AuditEntry
  some CareTeamMembership
}

// === Structural Invariants ===

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004, FR-006, FR-007
fact F_LeastPrivilege {
  // Clinicians can read only if on active care team
  all u: User, ae: AuditEntry |
    u.role = Clinician and ae.accessor_user_id = u.user_id and ae.operation = ReadOp and ae.outcome = Permitted implies
    (some m: CareTeamMembership | m.clinician = u and m.record.record_id = ae.record_id and m.status = Active)
  
  // Patients can read only their own assigned record
  all u: User, ae: AuditEntry |
    u.role = Patient and ae.accessor_user_id = u.user_id and ae.operation = ReadOp and ae.outcome = Permitted implies
    ae.record_id = u.assigned_record_id
  
  // Compliance officers cannot read clinical records
  all u: User, ae: AuditEntry |
    u.role = ComplianceOfficer and ae.accessor_user_id = u.user_id and ae.operation = ReadOp implies
    ae.outcome = Denied
  
  // Only clinicians can append notes
  all ae: AuditEntry |
    ae.operation = AppendOp and ae.outcome = Permitted implies
    ae.accessor_role = Clinician
}

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md User entity; spec.md FR-003
fact F_OwnershipExclusivity {
  all u: User | u.role = Patient implies (one r: Record | u.assigned_record_id = r.record_id)
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006
fact F_OwnershipBasedAccess {
  all u: User, ae: AuditEntry |
    u.role = Patient and ae.accessor_user_id = u.user_id and ae.outcome = Permitted and ae.operation = ReadOp implies
    ae.record_id = u.assigned_record_id
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012, FR-015; data-model.md clinical_notes, audit_entries
fact F_AppendOnlyNotes {
  all n1, n2: ClinicalNote |
    n1.note_id = n2.note_id implies
    (n1.body = n2.body and n1.created_at = n2.created_at and n1.author_user_id = n2.author_user_id and n1.record = n2.record)
}

fact F_AppendOnlyAuditEntries {
  all ae1, ae2: AuditEntry |
    ae1.entry_id = ae2.entry_id implies
    (ae1.timestamp = ae2.timestamp and ae1.accessor_user_id = ae2.accessor_user_id and ae1.outcome = ae2.outcome and ae1.operation = ae2.operation)
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md audit_entries
fact F_AuditCompleteness {
  all n: ClinicalNote |
    (one ae: AuditEntry | ae.note_id = n.note_id and ae.operation = AppendOp and ae.outcome = Permitted)
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md audit_entries
fact F_AttributionCorrectness {
  all ae: AuditEntry |
    (some u: User | u.user_id = ae.accessor_user_id and u.display_name = ae.accessor_user_display_name and u.role = ae.accessor_role)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
fact F_AuthRequiredEverywhere {
  all ae: AuditEntry | some u: User | u.user_id = ae.accessor_user_id
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008
fact F_NoInformationLeakage {
  all ae1, ae2: AuditEntry |
    ae1.accessor_user_id = ae2.accessor_user_id and
    ae1.record_id = ae2.record_id and
    ae1.operation = ae2.operation implies
    ae1.outcome = ae2.outcome
}

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-010; data-model.md clinical_notes
fact F_RecordIdNonNull {
  all ae: AuditEntry |
    (ae.operation = ReadOp or ae.operation = AppendOp) implies some ae.record_id
}

// === Assertions and Checks ===

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004, FR-006, FR-007
pred LeastPrivilege {
  all u: User, ae: AuditEntry |
    u.role = Clinician and ae.accessor_user_id = u.user_id and ae.operation = ReadOp and ae.outcome = Permitted implies
    (some m: CareTeamMembership | m.clinician = u and m.record.record_id = ae.record_id and m.status = Active)
  all u: User, ae: AuditEntry |
    u.role = Patient and ae.accessor_user_id = u.user_id and ae.outcome = Permitted and ae.operation = ReadOp implies
    ae.record_id = u.assigned_record_id
  some ae: AuditEntry | ae.outcome = Permitted
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md User entity; spec.md FR-003
pred OwnershipExclusivity {
  all u: User | u.role = Patient implies (one r: Record | u.assigned_record_id = r.record_id)
  some u: User | u.role = Patient
}

assert OwnershipExclusivity {
  OwnershipExclusivity
}

check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006
pred OwnershipBasedAccess {
  all u: User, ae: AuditEntry |
    u.role = Patient and ae.accessor_user_id = u.user_id and ae.outcome = Permitted and ae.operation = ReadOp implies
    ae.record_id = u.assigned_record_id
  some u: User | u.role = Patient
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012, FR-015; data-model.md clinical_notes, audit_entries
pred AppendOnly {
  all n1, n2: ClinicalNote |
    n1.note_id = n2.note_id implies (n1.body = n2.body and n1.created_at = n2.created_at)
  all ae1, ae2: AuditEntry |
    ae1.entry_id = ae2.entry_id implies (ae1.timestamp = ae2.timestamp and ae1.outcome = ae2.outcome)
  some n: ClinicalNote
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md audit_entries
pred AuditCompleteness {
  all n: ClinicalNote | (one ae: AuditEntry | ae.note_id = n.note_id and ae.operation = AppendOp and ae.outcome = Permitted)
  some n: ClinicalNote
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md audit_entries
pred AttributionCorrectness {
  all ae: AuditEntry |
    (some u: User | u.user_id = ae.accessor_user_id and u.role = ae.accessor_role)
  some ae: AuditEntry
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all ae: AuditEntry | some u: User | u.user_id = ae.accessor_user_id
  some ae: AuditEntry
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008
pred NoInformationLeakage {
  all ae1, ae2: AuditEntry |
    ae1.accessor_user_id = ae2.accessor_user_id and
    ae1.record_id = ae2.record_id and
    ae1.operation = ae2.operation implies
    ae1.outcome = ae2.outcome
  some ae: AuditEntry
}

assert NoInformationLeakage {
  NoInformationLeakage
}

check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 - Care Team Gating for Clinicians
pred FR_004_CareTeamGating {
  all u: User, ae: AuditEntry |
    u.role = Clinician and ae.accessor_user_id = u.user_id and ae.operation = ReadOp and ae.outcome = Permitted implies
    (some m: CareTeamMembership | m.clinician = u and m.record.record_id = ae.record_id and m.status = Active)
}

assert FR_004_CareTeamGating {
  FR_004_CareTeamGating
}

check FR_004_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 - Clinician Audit Access Restricted
pred FR_005_ClinicianAuditAccess {
  all u: User, ae: AuditEntry |
    u.role = Clinician and ae.accessor_user_id = u.user_id and ae.operation = ListOp and ae.outcome = Permitted implies
    (some m: CareTeamMembership | m.clinician = u and m.record.record_id = ae.record_id and m.status = Active)
}

assert FR_005_ClinicianAuditAccess {
  FR_005_ClinicianAuditAccess
}

check FR_005_ClinicianAuditAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 - Compliance Officer Cannot Read Clinical Records
pred FR_007_ComplianceNoRecordRead {
  all u: User, ae: AuditEntry |
    u.role = ComplianceOfficer and ae.accessor_user_id = u.user_id and ae.operation = ReadOp implies
    ae.outcome = Denied
}

assert FR_007_ComplianceNoRecordRead {
  FR_007_ComplianceNoRecordRead
}

check FR_007_ComplianceNoRecordRead for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 - Byte-Equivalent Forbidden Responses
pred FR_008_ByteEquivalentForbidden {
  all ae1, ae2: AuditEntry |
    ae1.accessor_user_id = ae2.accessor_user_id and
    ae1.record_id = ae2.record_id and
    ae1.operation = ae2.operation implies
    ae1.outcome = ae2.outcome
}

assert FR_008_ByteEquivalentForbidden {
  FR_008_ByteEquivalentForbidden
}

check FR_008_ByteEquivalentForbidden for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 - Clinical Notes Append-Only
pred FR_012_NotesAppendOnly {
  all n1, n2: ClinicalNote |
    n1.note_id = n2.note_id implies
    (n1.body = n2.body and n1.created_at = n2.created_at and n1.author_user_id = n2.author_user_id)
}

assert FR_012_NotesAppendOnly {
  FR_012_NotesAppendOnly
}

check FR_012_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 - Always-On Audit Completeness
pred FR_013_AlwaysOnAudit {
  all n: ClinicalNote | (one ae: AuditEntry | ae.note_id = n.note_id and ae.operation = AppendOp and ae.outcome = Permitted)
}

assert FR_013_AlwaysOnAudit {
  FR_013_AlwaysOnAudit
}

check FR_013_AlwaysOnAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 - Audit Entry IP Capture
pred FR_014_AuditCapturesIP {
  all ae: AuditEntry | some ae.originating_ip_address
}

assert FR_014_AuditCapturesIP {
  FR_014_AuditCapturesIP
}

check FR_014_AuditCapturesIP for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 - Audit Entry Immutability
pred FR_015_AuditImmutable {
  all ae1, ae2: AuditEntry |
    ae1.entry_id = ae2.entry_id implies
    (ae1.timestamp = ae2.timestamp and ae1.accessor_user_id = ae2.accessor_user_id)
}

assert FR_015_AuditImmutable {
  FR_015_AuditImmutable
}

check FR_015_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019 - Compliance Officer Content Blindness
pred FR_019_ComplianceContentBlind {
  all u: User, ae: AuditEntry |
    u.role = ComplianceOfficer and ae.accessor_user_id = u.user_id and ae.operation = ReadOp implies
    ae.outcome = Denied
}

assert FR_019_ComplianceContentBlind {
  FR_019_ComplianceContentBlind
}

check FR_019_ComplianceContentBlind for 5