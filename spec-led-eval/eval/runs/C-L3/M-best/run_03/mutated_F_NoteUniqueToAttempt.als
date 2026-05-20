// === feature_model.als — Alloy model for 013-hipaa-clinical-records (HIPAA Hospital Clinical Record Access) ===

// -----------------------------------------------------------------------------
// Non-empty universe so universally-quantified assertions can find witnesses.
// -----------------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some Record
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
  some AccessAttempt
}

// -----------------------------------------------------------------------------
// Enums (one-sig families)
// -----------------------------------------------------------------------------
abstract sig Role {}
one sig Clinician, Patient, ComplianceOfficer extends Role {}

abstract sig OperationKind {}
one sig GetRecord, PostNote, GetRecordAudit, GetAccessLog extends OperationKind {}

abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

abstract sig ResponseEnvelope {}
one sig ForbiddenEnvelope, OKEnvelope extends ResponseEnvelope {}

// -----------------------------------------------------------------------------
// Domain entities (data-model.md)
// -----------------------------------------------------------------------------
sig User {
  role: one Role,
  assignedRecord: lone Record   // FR-003: only set when role = Patient
}

sig Record {}

sig CareTeamMembership {
  ctClinician: one User,
  ctRecord: one Record
}

sig ClinicalNote {
  noteRecord: one Record,
  noteAuthor: one User
}

sig AuditEntry {
  recordedAccessor: one User,
  recordedRole: one Role,
  recordedOp: one OperationKind,
  recordedOutcome: one Outcome,
  recordedRecord: lone Record
}

sig AccessAttempt {
  caller: one User,
  targetRecord: lone Record,     // none only for GetAccessLog
  operation: one OperationKind,
  outcome: one Outcome,
  envelope: one ResponseEnvelope,
  createdNote: lone ClinicalNote,
  audit: one AuditEntry
}

// -----------------------------------------------------------------------------
// Permission matrix (contracts/http-api.md), encoded as a singleton-sig field.
// "Allowed" = cells where success is possible (subject to ownership).
// "OwnershipConditional" = cells whose allow requires an ownership-chain check.
// -----------------------------------------------------------------------------
one sig PermMatrix {
  Allowed: set Role -> OperationKind,
  OwnershipConditional: set Role -> OperationKind
}

fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Clinician -> GetRecord)
    + (Clinician -> PostNote)
    + (Clinician -> GetRecordAudit)
    + (Patient -> GetRecord)
    + (Patient -> GetRecordAudit)
    + (ComplianceOfficer -> GetRecordAudit)
    + (ComplianceOfficer -> GetAccessLog)

  PermMatrix.OwnershipConditional =
      (Clinician -> GetRecord)
    + (Clinician -> PostNote)
    + (Clinician -> GetRecordAudit)
    + (Patient -> GetRecord)
    + (Patient -> GetRecordAudit)
}

// -----------------------------------------------------------------------------
// Named structural facts (mutation-testable).
// -----------------------------------------------------------------------------

// FR-003 + data-model.md User pairing CHECK.
fact F_PatientAssignedRecord {
  all u: User | u.role = Patient iff some u.assignedRecord
}

// data-model.md CareTeamMembership: only clinicians populate it.
fact F_CareTeamClinicianOnly {
  all m: CareTeamMembership | m.ctClinician.role = Clinician
}

// data-model.md ClinicalNote CHECK(author_role='clinician'); FR-012.
fact F_ClinicianAuthorsOnly {
  all n: ClinicalNote | n.noteAuthor.role = Clinician
}

// FR-013 / FR-015: every AuditEntry belongs to exactly one AccessAttempt.
fact F_AuditUniqueToAttempt {
  all e: AuditEntry | one a: AccessAttempt | a.audit = e
}

// FR-012: every ClinicalNote belongs to exactly one creating AccessAttempt.
fact F_NoteUniqueToAttempt { /* MUTATED — body cleared by validator */ }

// FR-014: audit-entry fields are taken from the attempt (attribution snapshot).
fact F_AuditAttribution {
  all a: AccessAttempt |
        a.audit.recordedAccessor = a.caller
    and a.audit.recordedRole     = a.caller.role
    and a.audit.recordedOp       = a.operation
    and a.audit.recordedOutcome  = a.outcome
    and a.audit.recordedRecord   = a.targetRecord
}

// FR-008: denied -> ForbiddenEnvelope; permitted -> OKEnvelope.
fact F_DeniedEnvelope {
  all a: AccessAttempt | a.outcome = Denied    implies a.envelope = ForbiddenEnvelope
  all a: AccessAttempt | a.outcome = Permitted implies a.envelope = OKEnvelope
}

// LeastPrivilege backbone: permitted outcome requires the (role,op) cell in Allowed.
fact F_PermittedRequiresAllowed {
  all a: AccessAttempt |
    a.outcome = Permitted implies (a.caller.role -> a.operation) in PermMatrix.Allowed
}

// FR-004: permitted clinician access requires an active care-team membership.
fact F_ClinicianCareTeamGate {
  all a: AccessAttempt |
    (a.outcome = Permitted
     and a.caller.role = Clinician
     and (a.caller.role -> a.operation) in PermMatrix.OwnershipConditional)
    implies (some m: CareTeamMembership |
               m.ctClinician = a.caller and m.ctRecord = a.targetRecord)
}

// FR-006: permitted patient access targets only the patient's assigned record.
fact F_PatientSelfOnly {
  all a: AccessAttempt |
    (a.outcome = Permitted
     and a.caller.role = Patient
     and (a.caller.role -> a.operation) in PermMatrix.OwnershipConditional)
    implies a.targetRecord = a.caller.assignedRecord
}

// FR-011 + FR-013: a ClinicalNote materialises iff the attempt is a permitted PostNote.
fact F_NoteCreatedOnlyOnAppend {
  all a: AccessAttempt |
    (some a.createdNote) iff (a.operation = PostNote and a.outcome = Permitted)
}

// FR-011: created notes inherit attempt context (author + record).
fact F_NoteAttribution {
  all a: AccessAttempt |
    (some a.createdNote) implies
      (a.createdNote.noteAuthor = a.caller
       and a.createdNote.noteRecord = a.targetRecord)
}

// FR-020 / contracts: record-scoped ops carry a record; GetAccessLog does not.
fact F_TargetRecordRules {
  all a: AccessAttempt | a.operation = GetAccessLog implies no a.targetRecord
  all a: AccessAttempt | a.operation != GetAccessLog implies some a.targetRecord
}

// =============================================================================
// PATTERN-DERIVED PREDICATES
// =============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004..FR-007
pred LeastPrivilege {
  all a: AccessAttempt |
    a.outcome = Permitted implies (a.caller.role -> a.operation) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix (every cell decided)
pred PermissionCompleteness {
  all a: AccessAttempt |
    (a.caller.role -> a.operation) not in PermMatrix.Allowed
      implies a.outcome = Denied
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-004..FR-007; contracts/http-api.md matrix
pred PermissionGrounding {
  // every Allowed cell traces back to a documented FR-grounded grant
  PermMatrix.Allowed in
      ((Clinician -> GetRecord)
     + (Clinician -> PostNote)
     + (Clinician -> GetRecordAudit)
     + (Patient -> GetRecord)
     + (Patient -> GetRecordAudit)
     + (ComplianceOfficer -> GetRecordAudit)
     + (ComplianceOfficer -> GetAccessLog))
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all a: AccessAttempt | one a.caller and one a.caller.role
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md audit_entries one-to-one with access
pred AuditCompleteness {
  all a: AccessAttempt | one a.audit
  all disj a1, a2: AccessAttempt | a1.audit != a2.audit
  all e: AuditEntry | some a: AccessAttempt | a.audit = e
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-015, FR-017; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  // No two attempts may share an AuditEntry (entries are not reassigned/mutated).
  all disj a1, a2: AccessAttempt | a1.audit != a2.audit
  // Same for ClinicalNote: an existing note can't be rebound to a different attempt.
  all disj a1, a2: AccessAttempt |
    (some a1.createdNote) implies a1.createdNote != a2.createdNote
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md AuditEntry snapshot fields
pred AttributionCorrectness {
  all a: AccessAttempt |
        a.audit.recordedAccessor = a.caller
    and a.audit.recordedRole     = a.caller.role
    and a.audit.recordedOp       = a.operation
    and a.audit.recordedOutcome  = a.outcome
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-003; data-model.md User CHECK pairing
pred OwnershipExclusivity {
  all u: User | u.role = Patient    implies one u.assignedRecord
  all u: User | u.role != Patient   implies no  u.assignedRecord
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004 (clinician care-team) and FR-006 (patient self)
pred OwnershipBasedAccess {
  all a: AccessAttempt |
    (a.outcome = Permitted
     and a.caller.role = Clinician
     and (a.caller.role -> a.operation) in PermMatrix.OwnershipConditional)
    implies (some m: CareTeamMembership |
               m.ctClinician = a.caller and m.ctRecord = a.targetRecord)
  all a: AccessAttempt |
    (a.outcome = Permitted
     and a.caller.role = Patient
     and (a.caller.role -> a.operation) in PermMatrix.OwnershipConditional)
    implies a.targetRecord = a.caller.assignedRecord
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008; contracts/http-api.md byte-equivalent 403 envelope
pred NoInformationLeakage {
  // All denied responses share an identical envelope, regardless of record existence
  // or distinct reasons for refusal.
  all a1, a2: AccessAttempt |
    (a1.outcome = Denied and a2.outcome = Denied) implies a1.envelope = a2.envelope
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: NoSelfMutation  ANCHOR: spec.md FR-012; data-model.md clinical_notes append-only
//   (Reused here as: each note is bound to exactly one creating attempt; cannot be reassigned.)
pred NoSelfMutation {
  all n: ClinicalNote | one a: AccessAttempt | a.createdNote = n
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 6

// =============================================================================
// FEATURE-SPECIFIC PREDICATES — one per FR-NNN
// =============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 (auth required on every access)
pred FR_001_AuthRequired {
  all a: AccessAttempt | one a.caller and one a.audit.recordedAccessor
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 (exactly one role per user)
pred FR_002_OneRolePerUser {
  all u: User | one u.role
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 (patients get an assigned_record_id; others don't)
pred FR_003_PatientAssignedRecord {
  all u: User | u.role = Patient iff some u.assignedRecord
}
assert FR_003_PatientAssignedRecord { FR_003_PatientAssignedRecord }
check FR_003_PatientAssignedRecord for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 (clinician care-team gating)
pred FR_004_CareTeamGating {
  all a: AccessAttempt |
    (a.caller.role = Clinician
     and a.outcome = Permitted
     and (a.operation = GetRecord
          or a.operation = PostNote
          or a.operation = GetRecordAudit))
    implies (some m: CareTeamMembership |
               m.ctClinician = a.caller and m.ctRecord = a.targetRecord)
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 (clinicians may NOT call GetAccessLog)
pred FR_005_ClinicianNoAccessLog {
  no a: AccessAttempt |
    a.caller.role = Clinician
    and a.operation = GetAccessLog
    and a.outcome = Permitted
}
assert FR_005_ClinicianNoAccessLog { FR_005_ClinicianNoAccessLog }
check FR_005_ClinicianNoAccessLog for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 (patient self-access only; no writes)
pred FR_006_PatientSelfAccess {
  all a: AccessAttempt |
    (a.caller.role = Patient and a.outcome = Permitted)
    implies (a.targetRecord = a.caller.assignedRecord
             and (a.operation = GetRecord or a.operation = GetRecordAudit))
}
assert FR_006_PatientSelfAccess { FR_006_PatientSelfAccess }
check FR_006_PatientSelfAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 (compliance officer never reads clinical content)
pred FR_007_ComplianceNoClinicalContent {
  no a: AccessAttempt |
    a.caller.role = ComplianceOfficer
    and (a.operation = GetRecord or a.operation = PostNote)
    and a.outcome = Permitted
}
assert FR_007_ComplianceNoClinicalContent { FR_007_ComplianceNoClinicalContent }
check FR_007_ComplianceNoClinicalContent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 (byte-equivalent forbidden envelope)
pred FR_008_ByteEquivalentForbidden {
  all a1, a2: AccessAttempt |
    (a1.outcome = Denied and a2.outcome = Denied) implies a1.envelope = a2.envelope
}
assert FR_008_ByteEquivalentForbidden { FR_008_ByteEquivalentForbidden }
check FR_008_ByteEquivalentForbidden for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 (clinician not in care team is denied — structural piece of the 200ms 403 path)
pred FR_009_NonCareTeam403 {
  all a: AccessAttempt |
    (a.caller.role = Clinician
     and (a.operation = GetRecord
          or a.operation = PostNote
          or a.operation = GetRecordAudit)
     and (no m: CareTeamMembership |
            m.ctClinician = a.caller and m.ctRecord = a.targetRecord))
    implies a.outcome = Denied
}
assert FR_009_NonCareTeam403 { FR_009_NonCareTeam403 }
check FR_009_NonCareTeam403 for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 / FR-011 (notes materialise only as a permitted PostNote outcome)
pred FR_010_NoteOnAppendOnly {
  all n: ClinicalNote |
    some a: AccessAttempt |
      a.createdNote = n and a.operation = PostNote and a.outcome = Permitted
}
assert FR_010_NoteOnAppendOnly { FR_010_NoteOnAppendOnly }
check FR_010_NoteOnAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 (note attribution snapshot: author + record)
pred FR_011_NoteAttribution {
  all a: AccessAttempt |
    (some a.createdNote) implies
      (a.createdNote.noteAuthor = a.caller
       and a.createdNote.noteRecord = a.targetRecord)
}
assert FR_011_NoteAttribution { FR_011_NoteAttribution }
check FR_011_NoteAttribution for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 (notes are append-only; only clinicians author)
pred FR_012_AppendOnlyNotes {
  all n: ClinicalNote | one a: AccessAttempt | a.createdNote = n
  all n: ClinicalNote | n.noteAuthor.role = Clinician
}
assert FR_012_AppendOnlyNotes { FR_012_AppendOnlyNotes }
check FR_012_AppendOnlyNotes for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 (always-on audit; 1:1 between attempt and entry)
pred FR_013_AuditEveryAccess {
  all a: AccessAttempt | one a.audit
  all disj a1, a2: AccessAttempt | a1.audit != a2.audit
  all e: AuditEntry | some a: AccessAttempt | a.audit = e
}
assert FR_013_AuditEveryAccess { FR_013_AuditEveryAccess }
check FR_013_AuditEveryAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 (required audit fields match attempt)
pred FR_014_AuditFields {
  all a: AccessAttempt |
        a.audit.recordedAccessor = a.caller
    and a.audit.recordedRole     = a.caller.role
    and a.audit.recordedOp       = a.operation
    and a.audit.recordedOutcome  = a.outcome
}
assert FR_014_AuditFields { FR_014_AuditFields }
check FR_014_AuditFields for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 (audit entries are immutable — each bound to exactly one attempt)
pred FR_015_AuditImmutable {
  all e: AuditEntry | one a: AccessAttempt | a.audit = e
}
assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 (≥7-year retention modelled as: no orphaned/deleted audit entries)
pred FR_017_AuditRetained {
  all e: AuditEntry | some a: AccessAttempt | a.audit = e
}
assert FR_017_AuditRetained { FR_017_AuditRetained }
check FR_017_AuditRetained for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 (only compliance officers can be permitted on GetAccessLog)
pred FR_018_ComplianceOnlyAccessLog {
  all a: AccessAttempt |
    (a.operation = GetAccessLog and a.outcome = Permitted)
      implies a.caller.role = ComplianceOfficer
}
assert FR_018_ComplianceOnlyAccessLog { FR_018_ComplianceOnlyAccessLog }
check FR_018_ComplianceOnlyAccessLog for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 (content-blindness: compliance never sees clinical record content)
pred FR_019_ContentBlindness {
  no a: AccessAttempt |
    a.caller.role = ComplianceOfficer
    and a.operation = GetRecord
    and a.outcome = Permitted
}
assert FR_019_ContentBlindness { FR_019_ContentBlindness }
check FR_019_ContentBlindness for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020 (record_id is the only path placeholder; record-scoped ops carry one)
pred FR_020_RecordIdOnly {
  all a: AccessAttempt |
    (a.operation = GetRecord
     or a.operation = PostNote
     or a.operation = GetRecordAudit)
      implies one a.targetRecord
  all a: AccessAttempt |
    a.operation = GetAccessLog implies no a.targetRecord
}
assert FR_020_RecordIdOnly { FR_020_RecordIdOnly }
check FR_020_RecordIdOnly for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_NoteShared { some disj a1, a2: AccessAttempt | some a1.createdNote and a1.createdNote = a2.createdNote }
