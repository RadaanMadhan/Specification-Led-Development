// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===
// Feature: 013-hipaa-clinical-records (C-L3)
// Encodes the role/permission matrix, care-team gating, patient self-access,
// append-only notes & audit, and content-blindness invariants from spec.md.

// ---------- Static catalogues ----------

abstract sig Role {}
one sig Clinician, Patient, ComplianceOfficer extends Role {}

abstract sig OperationKind {}
one sig GetRecord, PostNote, GetRecordAudit, GetAccessLog extends OperationKind {}

abstract sig OpType {}
one sig ReadOp, AppendOp, ListOp extends OpType {}

abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

// ---------- Dynamic sigs ----------

sig Record {}

sig User {
  role: one Role,
  assignedRecord: lone Record
}

sig CareTeam {
  clinician: one User,
  ctRecord: one Record
}

sig ClinicalNote {
  noteRecord: one Record,
  author: one User
}

sig AuditEntry {
  auditRecord: lone Record,
  accessor: one User,
  accessorRole: one Role,
  auditOp: one OpType,
  auditOutcome: one Outcome,
  noteRef: lone ClinicalNote
}

sig Access {
  caller: one User,
  endpoint: one OperationKind,
  target: lone Record,
  result: one Outcome,
  audit: lone AuditEntry,
  noteCreated: lone ClinicalNote
}

// Permission matrix as a singleton-sig field
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Non-empty universe so all-quantifiers don't vacuously hold ----------

fact F_NonEmptyUniverse {
  some User
  some Record
  some CareTeam
  some ClinicalNote
  some AuditEntry
  some Access
}

// ---------- Permission matrix (contracts/http-api.md table) ----------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Clinician         -> GetRecord)
    + (Clinician         -> PostNote)
    + (Clinician         -> GetRecordAudit)
    + (Patient           -> GetRecord)
    + (Patient           -> GetRecordAudit)
    + (ComplianceOfficer -> GetRecordAudit)
    + (ComplianceOfficer -> GetAccessLog)
}

// ---------- Domain invariants ----------

// FR-003: patient ↔ has assigned record; others ↔ no assigned record
fact F_PatientAssignedRecord {
  all u: User | (u.role = Patient) iff (some u.assignedRecord)
}

// LeastPrivilege: every Permitted access lies in the allowed matrix
fact F_LeastPrivilegeMatrix {
  all a: Access |
    a.result = Permitted implies (a.caller.role -> a.endpoint) in PermMatrix.Allowed
}

// FR-004: clinician Permitted access on a record requires an active care-team membership
fact F_ClinicianRequiresCareTeam {
  all a: Access |
    (a.caller.role = Clinician and a.result = Permitted and
     a.endpoint in (GetRecord + PostNote + GetRecordAudit) and some a.target)
    implies (some ct: CareTeam | ct.clinician = a.caller and ct.ctRecord = a.target)
}

// FR-006: patient Permitted access only on their own assigned record
fact F_PatientOnlyOwnRecord { /* MUTATED — body cleared by validator */ }

// FR-013 / FR-016: exactly one audit entry per access; no orphan audit entries
fact F_OneAuditPerAccess {
  all a: Access | one a.audit
  all ae: AuditEntry | (one a: Access | a.audit = ae)
}

// FR-014: audit fields mirror the originating access (AttributionCorrectness)
fact F_AuditAttribution {
  all a: Access | {
    a.audit.accessor      = a.caller
    a.audit.accessorRole  = a.caller.role
    a.audit.auditOutcome  = a.result
    a.audit.auditRecord   = a.target
  }
}

// FR-014: opType matches endpoint
fact F_AuditOpType {
  all a: Access | {
    (a.endpoint = GetRecord)                          implies a.audit.auditOp = ReadOp
    (a.endpoint = PostNote)                           implies a.audit.auditOp = AppendOp
    (a.endpoint in (GetRecordAudit + GetAccessLog))   implies a.audit.auditOp = ListOp
  }
}

// FR-014: noteRef in audit set iff Permitted append
fact F_AuditNoteRefLink {
  all ae: AuditEntry |
    (some ae.noteRef) iff (ae.auditOp = AppendOp and ae.auditOutcome = Permitted)
}

// FR-014: record_id null only on access-log list events
fact F_AuditRecordPresence {
  all ae: AuditEntry | (no ae.auditRecord) implies ae.auditOp = ListOp
}

// FR-010 / FR-011 / FR-012: notes are created only by Permitted PostNote accesses,
// each note is uniquely tied to one creating access, and the author/record match.
fact F_NoteCreationLink {
  all a: Access |
    (some a.noteCreated) iff (a.endpoint = PostNote and a.result = Permitted)
  all a: Access |
    (some a.noteCreated)
      implies (a.noteCreated.author = a.caller and a.noteCreated.noteRecord = a.target)
  all n: ClinicalNote | (one a: Access | a.noteCreated = n)
}

// FR-010/FR-011 defence-in-depth: note authors are clinicians
fact F_NoteAuthorIsClinician {
  all n: ClinicalNote | n.author.role = Clinician
}

// Cross-check: audit's noteRef matches the note the access created
fact F_AuditNoteRefMatchesCreated {
  all a: Access | (some a.noteCreated) implies a.audit.noteRef = a.noteCreated
}

// FR-020: record-scoped endpoints carry a record; system-wide endpoint does not
fact F_RecordScopedHaveTarget {
  all a: Access |
    (a.endpoint in (GetRecord + PostNote + GetRecordAudit)) implies some a.target
  all a: Access |
    (a.endpoint = GetAccessLog) implies no a.target
}

// ====================================================================
//  PATTERN PREDICATES + ASSERTIONS + CHECKS
// ====================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004..FR-007
pred LeastPrivilege {
  some Access
  all a: Access |
    a.result = Permitted implies (a.caller.role -> a.endpoint) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md matrix (every cell has a verdict)
pred PermissionCompleteness {
  all r: Role | (some op: OperationKind | (r -> op) in PermMatrix.Allowed)
  all r: Role | (some op: OperationKind | (r -> op) not in PermMatrix.Allowed)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, SC-009
pred AuthRequiredEverywhere {
  some Access
  all a: Access | (some a.caller and one a.audit)
  all ae: AuditEntry | some ae.accessor
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md audit-entry pairing CHECKs
pred AuditCompleteness {
  some Access
  all a: Access | one a.audit
  all disj a1, a2: Access | a1.audit != a2.audit
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012, FR-015; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  some ClinicalNote
  all n: ClinicalNote  | (one a: Access | a.noteCreated = n)
  all ae: AuditEntry   | (one a: Access | a.audit = ae)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md AuditEntry fields
pred AttributionCorrectness {
  some Access
  all a: Access | {
    a.audit.accessor      = a.caller
    a.audit.accessorRole  = a.caller.role
    a.audit.auditOutcome  = a.result
    a.audit.auditRecord   = a.target
  }
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004 (care team) and FR-006 (patient self)
pred OwnershipBasedAccess {
  all a: Access |
    (a.caller.role = Patient and a.result = Permitted and some a.target)
      implies a.target = a.caller.assignedRecord
  all a: Access |
    (a.caller.role = Clinician and a.result = Permitted and
     a.endpoint in (GetRecord + PostNote + GetRecordAudit) and some a.target)
      implies (some ct: CareTeam | ct.clinician = a.caller and ct.ctRecord = a.target)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008, SC-003
pred NoInformationLeakage {
  // Denied accesses have no clinical side-effect (no note persisted)
  all a: Access | a.result = Denied implies no a.noteCreated
  // Denial audit-entries carry outcome=Denied (no leak via audit shape)
  all a: Access | a.result = Denied implies a.audit.auditOutcome = Denied
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-010, FR-016
pred ValidationBeforeMutation {
  all a: Access | a.result = Denied implies no a.noteCreated
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// ====================================================================
//  PER-FR PREDICATES + ASSERTIONS + CHECKS
// ====================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some Access
  all a: Access | (some a.caller and one a.audit)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_OneRolePerUser {
  some User
  all u: User | one u.role
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_PatientAssignedRecord {
  all u: User | (u.role = Patient) iff (some u.assignedRecord)
}
assert FR_003_PatientAssignedRecord { FR_003_PatientAssignedRecord }
check FR_003_PatientAssignedRecord for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_CareTeamGating {
  all a: Access |
    (a.caller.role = Clinician and a.result = Permitted and
     a.endpoint in (GetRecord + PostNote + GetRecordAudit) and some a.target)
      implies (some ct: CareTeam | ct.clinician = a.caller and ct.ctRecord = a.target)
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_ClinicianNoAccessLog {
  all a: Access |
    (a.caller.role = Clinician and a.endpoint = GetAccessLog) implies a.result = Denied
}
assert FR_005_ClinicianNoAccessLog { FR_005_ClinicianNoAccessLog }
check FR_005_ClinicianNoAccessLog for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_PatientSelfAccess {
  all a: Access |
    (a.caller.role = Patient and a.result = Permitted)
      implies (a.endpoint in (GetRecord + GetRecordAudit)
               and a.target = a.caller.assignedRecord)
}
assert FR_006_PatientSelfAccess { FR_006_PatientSelfAccess }
check FR_006_PatientSelfAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_ComplianceNoClinical {
  all a: Access |
    (a.caller.role = ComplianceOfficer and a.endpoint in (GetRecord + PostNote))
      implies a.result = Denied
}
assert FR_007_ComplianceNoClinical { FR_007_ComplianceNoClinical }
check FR_007_ComplianceNoClinical for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_ByteEquivalentDenial {
  all a: Access | a.result = Denied implies no a.noteCreated
  all a: Access | a.result = Denied implies a.audit.auditOutcome = Denied
}
assert FR_008_ByteEquivalentDenial { FR_008_ByteEquivalentDenial }
check FR_008_ByteEquivalentDenial for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_DenialAudited {
  all a: Access | a.result = Denied implies one a.audit
}
assert FR_009_DenialAudited { FR_009_DenialAudited }
check FR_009_DenialAudited for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_NoteAuthorIsClinician {
  some ClinicalNote
  all n: ClinicalNote | n.author.role = Clinician
}
assert FR_010_NoteAuthorIsClinician { FR_010_NoteAuthorIsClinician }
check FR_010_NoteAuthorIsClinician for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_NoteAttribution {
  all a: Access |
    (some a.noteCreated)
      implies (a.noteCreated.author = a.caller and a.noteCreated.noteRecord = a.target)
}
assert FR_011_NoteAttribution { FR_011_NoteAttribution }
check FR_011_NoteAttribution for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_NotesAppendOnly {
  some ClinicalNote
  all n: ClinicalNote | (one a: Access | a.noteCreated = n)
}
assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_OneAuditPerAccess {
  some Access
  all a: Access | one a.audit
  all disj a1, a2: Access | a1.audit != a2.audit
}
assert FR_013_OneAuditPerAccess { FR_013_OneAuditPerAccess }
check FR_013_OneAuditPerAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_AuditFields {
  all a: Access | {
    a.audit.accessor      = a.caller
    a.audit.accessorRole  = a.caller.role
    a.audit.auditOutcome  = a.result
    a.audit.auditRecord   = a.target
  }
  all ae: AuditEntry |
    (some ae.noteRef) iff (ae.auditOp = AppendOp and ae.auditOutcome = Permitted)
}
assert FR_014_AuditFields { FR_014_AuditFields }
check FR_014_AuditFields for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_AuditImmutable {
  some AuditEntry
  all ae: AuditEntry | (one a: Access | a.audit = ae)
}
assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016
pred FR_016_AuditSLA {
  some Access
  all a: Access | one a.audit
}
assert FR_016_AuditSLA { FR_016_AuditSLA }
check FR_016_AuditSLA for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditRetention {
  some AuditEntry
  all ae: AuditEntry | (one a: Access | a.audit = ae)
}
assert FR_017_AuditRetention { FR_017_AuditRetention }
check FR_017_AuditRetention for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_AccessLogComplianceOnly {
  all a: Access |
    (a.endpoint = GetAccessLog and a.result = Permitted)
      implies a.caller.role = ComplianceOfficer
}
assert FR_018_AccessLogComplianceOnly { FR_018_AccessLogComplianceOnly }
check FR_018_AccessLogComplianceOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019
pred FR_019_ComplianceContentBlind {
  all a: Access |
    (a.caller.role = ComplianceOfficer and a.result = Permitted)
      implies a.endpoint in (GetRecordAudit + GetAccessLog)
}
assert FR_019_ComplianceContentBlind { FR_019_ComplianceContentBlind }
check FR_019_ComplianceContentBlind for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020
pred FR_020_RecordIdOpaque {
  all a: Access |
    (a.endpoint in (GetRecord + PostNote + GetRecordAudit)) implies some a.target
  all a: Access |
    (a.endpoint = GetAccessLog) implies no a.target
}
assert FR_020_RecordIdOpaque { FR_020_RecordIdOpaque }
check FR_020_RecordIdOpaque for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_PatientCrossRecord { some a: Access | a.caller.role = Patient and a.result = Permitted and some a.target and a.target != a.caller.assignedRecord }
