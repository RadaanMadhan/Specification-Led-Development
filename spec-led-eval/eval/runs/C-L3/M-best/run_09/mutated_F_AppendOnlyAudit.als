// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access (013) ===
//
// Self-contained Alloy 6 model. Encodes the per-role permission matrix for the
// four endpoints (GET /records/{id}, POST /records/{id}/notes,
// GET /records/{id}/audit, GET /access-log), the care-team-membership gating,
// the patient self-access constraint, the append-only audit / clinical-notes
// rules, and the byte-equivalent denied-response invariant.

// ---------- Booleans (used as flags) ----------
abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

// ---------- Roles ----------
abstract sig Role {}
one sig Clinician, Patient, ComplianceOfficer extends Role {}

// ---------- Operation types (audit field) ----------
abstract sig Operation {}
one sig OpRead, OpAppend, OpList extends Operation {}

// ---------- Outcomes ----------
abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

// ---------- The four endpoints ----------
abstract sig OperationKind {}
one sig GetRecord, PostNotes, GetRecordAudit, GetAccessLog extends OperationKind {}

// ---------- Entities ----------
sig User {
  role: one Role,
  assignedRecord: lone Record
}

sig Record {}

sig CareTeamMembership {
  ctClinician: one User,
  ctRecord: one Record,
  ctActive: one Bool
}

sig ClinicalNote {
  noteRecord: one Record,
  noteAuthor: one User,
  noteAuthorRoleSnapshot: one Role
}

sig AccessEvent {
  caller: one User,
  callerRoleSnap: one Role,
  endpoint: one OperationKind,
  opType: one Operation,
  target: lone Record,
  outcome: one Outcome,
  createdNote: lone ClinicalNote,
  authenticated: one Bool,
  validRequest: one Bool
}

sig AuditEntry {
  auditEvent: one AccessEvent,
  recordedRecord: lone Record,
  recordedAccessor: one User,
  recordedRole: one Role,
  recordedOperation: one Operation,
  recordedOutcome: one Outcome,
  hasIP: one Bool,
  recordedNote: lone ClinicalNote
}

// ---------- Permission matrix as a singleton-sig field (documentary) ----------
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ============================================================
// Non-empty universe — single named fact (per protocol rule 9)
// ============================================================
fact F_NonEmptyUniverse {
  some User
  some Record
  some AccessEvent
  some AuditEntry
  some ClinicalNote
  some CareTeamMembership
}

// ============================================================
// Permission matrix definition (contracts/http-api.md)
// ============================================================
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Clinician         -> GetRecord) +
    (Clinician         -> PostNotes) +
    (Clinician         -> GetRecordAudit) +
    (Patient           -> GetRecord) +
    (Patient           -> GetRecordAudit) +
    (ComplianceOfficer -> GetRecordAudit) +
    (ComplianceOfficer -> GetAccessLog)
}

// ============================================================
// Structural plumbing
// ============================================================

fact F_EndpointDeterminesOp {
  all e: AccessEvent |
    (e.endpoint = GetRecord       implies e.opType = OpRead)   and
    (e.endpoint = PostNotes       implies e.opType = OpAppend) and
    (e.endpoint = GetRecordAudit  implies e.opType = OpList)   and
    (e.endpoint = GetAccessLog    implies e.opType = OpList)
}

fact F_EndpointTargetCardinality {
  all e: AccessEvent |
    (e.endpoint = GetAccessLog  implies no e.target) and
    (e.endpoint != GetAccessLog implies some e.target)
}

fact F_CallerRoleSnap {
  all e: AccessEvent | e.callerRoleSnap = e.caller.role
}

fact F_PatientAssignment {
  all u: User | (u.role = Patient) iff (some u.assignedRecord)
}

// ============================================================
// Authentication boundary (FR-001)
// ============================================================

fact F_AuthRequiredForPermitted {
  all e: AccessEvent | e.authenticated = BFalse implies e.outcome = Denied
}

fact F_NoAuditForUnauthenticated {
  all e: AccessEvent | e.authenticated = BFalse implies (no a: AuditEntry | a.auditEvent = e)
}

// ============================================================
// Audit linkage (FR-013, FR-014, FR-015)
// ============================================================

fact F_AuditExistsForAuthenticated {
  all e: AccessEvent | e.authenticated = BTrue implies (some a: AuditEntry | a.auditEvent = e)
}

fact F_NoOrphanAudits {
  all a: AuditEntry | a.auditEvent.authenticated = BTrue
}

fact F_AppendOnlyAudit { /* MUTATED — body cleared by validator */ }

fact F_AuditAttribution {
  all a: AuditEntry |
    a.recordedAccessor   = a.auditEvent.caller          and
    a.recordedRole       = a.auditEvent.callerRoleSnap  and
    a.recordedOperation  = a.auditEvent.opType          and
    a.recordedOutcome    = a.auditEvent.outcome         and
    a.recordedRecord     = a.auditEvent.target
}

fact F_AuditIPRequired {
  all a: AuditEntry | a.hasIP = BTrue
}

fact F_AuditNoteLinkage {
  all a: AuditEntry | a.recordedNote = a.auditEvent.createdNote
  all a: AuditEntry |
    (a.recordedOperation = OpAppend and a.recordedOutcome = Permitted) iff some a.recordedNote
}

// ============================================================
// Notes (FR-010, FR-011, FR-012)
// ============================================================

fact F_NoteOnlyOnPermittedAppend {
  all e: AccessEvent |
    some e.createdNote implies (e.endpoint = PostNotes and e.outcome = Permitted)
}

fact F_PermittedAppendCreatesNote {
  all e: AccessEvent |
    (e.endpoint = PostNotes and e.outcome = Permitted) implies some e.createdNote
}

fact F_NoteAuthorIsCaller {
  all e: AccessEvent |
    some e.createdNote implies
      (e.createdNote.noteAuthor = e.caller and e.createdNote.noteRecord = e.target)
}

fact F_NoteAuthorIsClinician {
  all n: ClinicalNote | n.noteAuthorRoleSnapshot = Clinician
  all n: ClinicalNote | n.noteAuthor.role = Clinician
}

fact F_AppendOnlyNotes {
  all n: ClinicalNote | (one e: AccessEvent | e.createdNote = n)
}

// ============================================================
// Validation before mutation (FR-010)
// ============================================================

fact F_ValidationBeforeMutation {
  all e: AccessEvent | e.validRequest = BFalse implies (no e.createdNote and e.outcome = Denied)
}

// ============================================================
// Authorisation rules — per-role, per-endpoint
// ============================================================

// FR-004: clinicians may touch record-scoped endpoints only when on the care team.
fact F_ClinicianCareTeamRequired {
  all e: AccessEvent |
    (e.caller.role = Clinician and
     e.endpoint in (GetRecord + PostNotes + GetRecordAudit) and
     e.outcome = Permitted) implies
       (some m: CareTeamMembership |
          m.ctClinician = e.caller and
          m.ctRecord    = e.target and
          m.ctActive    = BTrue)
}

// FR-005: clinicians cannot read the system-wide access log.
fact F_ClinicianCannotAccessLog {
  all e: AccessEvent |
    (e.caller.role = Clinician and e.endpoint = GetAccessLog) implies e.outcome = Denied
}

// FR-006: patients may only access their own assigned record.
fact F_PatientSelfOnly {
  all e: AccessEvent |
    (e.caller.role = Patient and
     e.endpoint in (GetRecord + GetRecordAudit) and
     e.outcome = Permitted) implies
       e.target = e.caller.assignedRecord
}

// FR-006: patients cannot post notes.
fact F_PatientCannotAppendNote {
  all e: AccessEvent |
    (e.caller.role = Patient and e.endpoint = PostNotes) implies e.outcome = Denied
}

// FR-006: patients cannot read the system-wide access log.
fact F_PatientCannotAccessLog {
  all e: AccessEvent |
    (e.caller.role = Patient and e.endpoint = GetAccessLog) implies e.outcome = Denied
}

// FR-007: compliance officers cannot read record clinical content.
fact F_ComplianceCannotReadRecord {
  all e: AccessEvent |
    (e.caller.role = ComplianceOfficer and e.endpoint = GetRecord) implies e.outcome = Denied
}

// FR-007: compliance officers cannot append notes.
fact F_ComplianceCannotAppendNote {
  all e: AccessEvent |
    (e.caller.role = ComplianceOfficer and e.endpoint = PostNotes) implies e.outcome = Denied
}

// ============================================================
// CATALOGUE PATTERNS
// ============================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-004..FR-007
pred LeastPrivilege {
  // A Permitted outcome can only occur on a (role, endpoint) cell that the
  // matrix explicitly allows.
  all e: AccessEvent | e.outcome = Permitted implies (
    (e.callerRoleSnap = Clinician         and e.endpoint in (GetRecord + PostNotes + GetRecordAudit)) or
    (e.callerRoleSnap = Patient           and e.endpoint in (GetRecord + GetRecordAudit)) or
    (e.callerRoleSnap = ComplianceOfficer and e.endpoint in (GetRecordAudit + GetAccessLog))
  )
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  PermMatrix.Allowed =
    (Clinician         -> GetRecord) +
    (Clinician         -> PostNotes) +
    (Clinician         -> GetRecordAudit) +
    (Patient           -> GetRecord) +
    (Patient           -> GetRecordAudit) +
    (ComplianceOfficer -> GetRecordAudit) +
    (ComplianceOfficer -> GetAccessLog)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all e: AccessEvent | e.outcome = Permitted implies e.authenticated = BTrue
  all a: AuditEntry  | a.auditEvent.authenticated = BTrue
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md audit_entries
pred AuditCompleteness {
  all e: AccessEvent | e.authenticated = BTrue implies (one a: AuditEntry | a.auditEvent = e)
  all a: AuditEntry  | a.auditEvent.authenticated = BTrue
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012 (notes) and FR-015 (audit)
pred AppendOnly {
  // No two audit entries pinned to the same access event (no overwrite/replace).
  all disj a1, a2: AuditEntry | a1.auditEvent != a2.auditEvent
  // Each clinical note has a unique creating event (no duplication/mutation).
  all n: ClinicalNote | (one e: AccessEvent | e.createdNote = n)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014
pred AttributionCorrectness {
  all a: AuditEntry |
    a.recordedAccessor  = a.auditEvent.caller        and
    a.recordedRole      = a.auditEvent.caller.role   and
    a.recordedOperation = a.auditEvent.opType        and
    a.recordedOutcome   = a.auditEvent.outcome
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-003; data-model.md users.assigned_record_id pairing CHECK
pred OwnershipExclusivity {
  all u: User | u.role = Patient  implies one u.assignedRecord
  all u: User | u.role != Patient implies no  u.assignedRecord
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004 (care team), FR-006 (patient self)
pred OwnershipBasedAccess {
  all e: AccessEvent |
    (e.caller.role = Clinician and
     e.endpoint in (GetRecord + PostNotes + GetRecordAudit) and
     e.outcome = Permitted) implies
       (some m: CareTeamMembership |
          m.ctClinician = e.caller and
          m.ctRecord    = e.target and
          m.ctActive    = BTrue)
  all e: AccessEvent |
    (e.caller.role = Patient and
     e.endpoint in (GetRecord + GetRecordAudit) and
     e.outcome = Permitted) implies
       e.target = e.caller.assignedRecord
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008 (byte-equivalent denied)
pred NoInformationLeakage {
  // A denied response never leaks record-specific state: no note is created,
  // and the audit envelope carries no note id. This is the structural form of
  // "the wire response shape does not depend on whether the record exists".
  all e: AccessEvent | e.outcome = Denied implies no e.createdNote
  all a: AuditEntry  | a.recordedOutcome = Denied implies no a.recordedNote
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-010
pred ValidationBeforeMutation {
  all e: AccessEvent | e.validRequest = BFalse implies (no e.createdNote and e.outcome = Denied)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// ============================================================
// FEATURE-SPECIFIC predicates (one per FR-NNN)
// ============================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all e: AccessEvent | e.authenticated = BFalse implies e.outcome = Denied
  all e: AccessEvent | e.authenticated = BFalse implies (no a: AuditEntry | a.auditEvent = e)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 (exactly one role per user)
pred FR_002_OneRolePerUser {
  all u: User | one u.role
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 (patient ↔ assigned record pairing)
pred FR_003_PatientAssignedRecord {
  all u: User | (u.role = Patient) iff (some u.assignedRecord)
}
assert FR_003_PatientAssignedRecord { FR_003_PatientAssignedRecord }
check FR_003_PatientAssignedRecord for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 (clinician requires active care-team membership)
pred FR_004_ClinicianCareTeam {
  all e: AccessEvent |
    (e.caller.role = Clinician and
     e.endpoint in (GetRecord + PostNotes) and
     e.outcome = Permitted) implies
       (some m: CareTeamMembership |
          m.ctClinician = e.caller and
          m.ctRecord    = e.target and
          m.ctActive    = BTrue)
}
assert FR_004_ClinicianCareTeam { FR_004_ClinicianCareTeam }
check FR_004_ClinicianCareTeam for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 (clinicians cannot read system-wide access log)
pred FR_005_ClinicianNoAccessLog {
  all e: AccessEvent |
    (e.caller.role = Clinician and e.endpoint = GetAccessLog) implies e.outcome = Denied
}
assert FR_005_ClinicianNoAccessLog { FR_005_ClinicianNoAccessLog }
check FR_005_ClinicianNoAccessLog for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 (patient self-only; no notes; no access log)
pred FR_006_PatientOwnOnly {
  all e: AccessEvent |
    (e.caller.role = Patient and
     e.endpoint in (GetRecord + GetRecordAudit) and
     e.outcome = Permitted) implies
       e.target = e.caller.assignedRecord
  all e: AccessEvent |
    (e.caller.role = Patient and e.endpoint = PostNotes) implies e.outcome = Denied
  all e: AccessEvent |
    (e.caller.role = Patient and e.endpoint = GetAccessLog) implies e.outcome = Denied
}
assert FR_006_PatientOwnOnly { FR_006_PatientOwnOnly }
check FR_006_PatientOwnOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 (compliance no clinical-content endpoints)
pred FR_007_ComplianceNoClinicalRead {
  all e: AccessEvent |
    (e.caller.role = ComplianceOfficer and e.endpoint in (GetRecord + PostNotes)) implies
      e.outcome = Denied
}
assert FR_007_ComplianceNoClinicalRead { FR_007_ComplianceNoClinicalRead }
check FR_007_ComplianceNoClinicalRead for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 (byte-equivalent denied response — no leak)
pred FR_008_ByteEquivalent {
  // Externally observable denied responses do not depend on target existence:
  // denied events never produce notes, and their audit envelopes carry no
  // note id.
  all e: AccessEvent | e.outcome = Denied implies no e.createdNote
  all a: AuditEntry  | a.recordedOutcome = Denied implies no a.recordedNote
}
assert FR_008_ByteEquivalent { FR_008_ByteEquivalent }
check FR_008_ByteEquivalent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 (validation precedes mutation)
pred FR_010_ValidationFirst {
  all e: AccessEvent | e.validRequest = BFalse implies (e.outcome = Denied and no e.createdNote)
}
assert FR_010_ValidationFirst { FR_010_ValidationFirst }
check FR_010_ValidationFirst for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 (note author role snapshotted as clinician)
pred FR_011_NoteAuthorClinician {
  all n: ClinicalNote | n.noteAuthorRoleSnapshot = Clinician
  all n: ClinicalNote | n.noteAuthor.role = Clinician
}
assert FR_011_NoteAuthorClinician { FR_011_NoteAuthorClinician }
check FR_011_NoteAuthorClinician for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 (notes append-only)
pred FR_012_NotesAppendOnly {
  all n: ClinicalNote | (one e: AccessEvent | e.createdNote = n)
  all e: AccessEvent  | some e.createdNote implies (e.endpoint = PostNotes and e.outcome = Permitted)
}
assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 (one audit per access)
pred FR_013_AuditAlways {
  all e: AccessEvent | e.authenticated = BTrue implies (one a: AuditEntry | a.auditEvent = e)
  all a: AuditEntry  | a.auditEvent.authenticated = BTrue
}
assert FR_013_AuditAlways { FR_013_AuditAlways }
check FR_013_AuditAlways for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 (audit fields shape)
pred FR_014_AuditFields {
  all a: AuditEntry |
    a.recordedAccessor   = a.auditEvent.caller          and
    a.recordedRole       = a.auditEvent.callerRoleSnap  and
    a.recordedOperation  = a.auditEvent.opType          and
    a.recordedOutcome    = a.auditEvent.outcome         and
    a.recordedRecord     = a.auditEvent.target          and
    a.hasIP              = BTrue                        and
    ((a.recordedOperation = OpAppend and a.recordedOutcome = Permitted) iff some a.recordedNote)
}
assert FR_014_AuditFields { FR_014_AuditFields }
check FR_014_AuditFields for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 (audit immutable / append-only)
pred FR_015_AuditImmutable {
  all disj a1, a2: AuditEntry | a1.auditEvent != a2.auditEvent
}
assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 (access log is compliance-officer-only)
pred FR_018_AccessLogComplianceOnly {
  all e: AccessEvent |
    (e.endpoint = GetAccessLog and e.outcome = Permitted) implies
      e.caller.role = ComplianceOfficer
}
assert FR_018_AccessLogComplianceOnly { FR_018_AccessLogComplianceOnly }
check FR_018_AccessLogComplianceOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 (compliance content-blindness)
pred FR_019_ComplianceContentBlind {
  // A compliance officer's permitted access touches only the audit-shaped
  // endpoints and never produces clinical content (no note creation).
  all e: AccessEvent |
    (e.caller.role = ComplianceOfficer and e.outcome = Permitted) implies
      (e.endpoint in (GetRecordAudit + GetAccessLog) and no e.createdNote)
}
assert FR_019_ComplianceContentBlind { FR_019_ComplianceContentBlind }
check FR_019_ComplianceContentBlind for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AppendOnlyAuditViolation { some disj a1, a2: AuditEntry | a1.auditEvent = a2.auditEvent }
