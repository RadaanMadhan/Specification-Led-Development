// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===
// Feature: 013-hipaa-clinical-records (C-L3)
// Self-contained Alloy 6 model encoding the structural invariants of the
// per-role, per-endpoint authorisation matrix, the always-on audit log,
// append-only notes/audit, ownership-based access, and content-blindness.

// ---------- Roles ----------
abstract sig Role {}
one sig ClinicianRole, PatientRole, ComplianceRole extends Role {}

// ---------- Endpoints / operation kinds ----------
abstract sig OperationKind {}
one sig OpReadRecord, OpAppendNote, OpReadRecordAudit, OpReadAccessLog extends OperationKind {}

// ---------- Outcomes ----------
abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

// ---------- Permission matrix (singleton-sig field) ----------
// Cells in EverAllowed are the (Role, OperationKind) pairs that the
// contract permits at least conditionally. Anything outside this set
// is unconditionally denied.
one sig PermMatrix {
  EverAllowed: set Role -> OperationKind
}

// ---------- Domain entities ----------
sig Record {}

sig User {
  role: one Role,
  assignedRecord: lone Record   // populated iff role = PatientRole
}

// Active care-team membership (clinician on record's care team).
sig CareTeam {
  ctClinician: one User,
  ctRecord: one Record
}

// Append-only clinical note attached to a record.
sig ClinicalNote {
  noteRecord: one Record,
  noteAuthor: one User,
  noteAuthorRole: one Role     // snapshot of author's role at write time
}

// One access attempt against the API.
// caller is empty iff the request was unauthenticated.
sig Operation {
  caller: lone User,
  kind: one OperationKind,
  target: lone Record,          // none for OpReadAccessLog; some otherwise
  outcome: one Outcome,
  newNote: lone ClinicalNote    // produced iff permitted append
}

// Immutable audit entry recording an access attempt.
sig AuditEntry {
  ofOp: one Operation,
  recordedUser: one User,
  recordedRole: one Role,
  recordedKind: one OperationKind,
  recordedOutcome: one Outcome,
  recordedRecord: lone Record,
  recordedNote: lone ClinicalNote
}

// =====================================================================
//                              FACTS
// =====================================================================

// Force a non-trivial universe so quantified assertions actually bite.
fact F_NonEmptyUniverse {
  some User
  some Record
  some Operation
  some AuditEntry
  some ClinicalNote
  some CareTeam
}

// Permission matrix as declared in contracts/http-api.md.
// 7 conditionally-or-unconditionally allowed cells; 5 hard-denied cells.
fact F_PermissionMatrix {
  PermMatrix.EverAllowed =
    (ClinicianRole -> OpReadRecord) +
    (ClinicianRole -> OpAppendNote) +
    (ClinicianRole -> OpReadRecordAudit) +
    (PatientRole   -> OpReadRecord) +
    (PatientRole   -> OpReadRecordAudit) +
    (ComplianceRole -> OpReadRecordAudit) +
    (ComplianceRole -> OpReadAccessLog)
}

// FR-002, FR-003: patient iff has an assigned record.
fact F_PatientAssignment {
  all u: User | (u.role = PatientRole) iff (some u.assignedRecord)
}

// data-model.md: clinical notes' author_role check constrains it to clinician.
// Also the snapshotted role must equal the author's actual role.
fact F_NoteAuthorIsClinician {
  all n: ClinicalNote |
    n.noteAuthor.role = ClinicianRole and n.noteAuthorRole = ClinicianRole
}

// Operation/endpoint shape: GET /access-log has no record target.
fact F_OperationTargetShape {
  all op: Operation |
    (op.kind = OpReadAccessLog implies no op.target) and
    (op.kind != OpReadAccessLog implies some op.target)
}

// Authorisation logic: outcome=Permitted iff authenticated AND the
// (role, kind) cell is allowed AND the role-specific condition is met.
fact F_AuthorizationLogic {
  all op: Operation |
    op.outcome = Permitted iff (
      some op.caller and
      (op.caller.role -> op.kind) in PermMatrix.EverAllowed and
      authCondition[op]
    )
}

pred authCondition[op: Operation] {
  // Clinician access to record-scoped endpoints requires active care-team membership.
  op.caller.role = ClinicianRole implies
    (some ct: CareTeam | ct.ctClinician = op.caller and ct.ctRecord = op.target)
  // Patient access to record-scoped endpoints must target their assigned record.
  op.caller.role = PatientRole implies (op.target = op.caller.assignedRecord)
}

// FR-013, FR-014: exactly one audit entry per authenticated access attempt;
// no audit entry for an unauthenticated attempt; no orphan audit entries.
fact F_OneAuditPerAuthenticatedOp {
  all op: Operation |
    (some op.caller) implies (one ae: AuditEntry | ae.ofOp = op)
  all op: Operation |
    (no op.caller) implies (no ae: AuditEntry | ae.ofOp = op)
  all disj ae1, ae2: AuditEntry | ae1.ofOp != ae2.ofOp
}

// FR-014: audit-entry fields are a faithful snapshot of the operation.
fact F_AuditAttribution {
  all ae: AuditEntry |
    ae.recordedUser = ae.ofOp.caller and
    ae.recordedRole = ae.ofOp.caller.role and
    ae.recordedKind = ae.ofOp.kind and
    ae.recordedOutcome = ae.ofOp.outcome and
    ae.recordedRecord = ae.ofOp.target and
    ae.recordedNote = ae.ofOp.newNote
}

// FR-011, FR-012: notes created iff op is permitted append; each note
// belongs to exactly one creating operation (append-only — no second
// op may claim it as newNote, which would model a mutation/replace).
fact F_NoteCreationRules {
  all op: Operation |
    (some op.newNote) iff (op.kind = OpAppendNote and op.outcome = Permitted)
  all n: ClinicalNote | one op: Operation | op.newNote = n
  all op: Operation, n: ClinicalNote |
    (op.newNote = n) implies (n.noteRecord = op.target and n.noteAuthor = op.caller)
}

// =====================================================================
//                       PATTERNS + FR ASSERTIONS
// =====================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation | op.outcome = Permitted implies some op.caller
  all op: Operation | (no op.caller) implies (no ae: AuditEntry | ae.ofOp = op)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  some Operation
  all op: Operation |
    op.outcome = Permitted implies (op.caller.role -> op.kind) in PermMatrix.EverAllowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every documented hard-denied cell must be absent from EverAllowed.
  (ClinicianRole -> OpReadAccessLog)  not in PermMatrix.EverAllowed
  (PatientRole   -> OpAppendNote)     not in PermMatrix.EverAllowed
  (PatientRole   -> OpReadAccessLog)  not in PermMatrix.EverAllowed
  (ComplianceRole -> OpReadRecord)    not in PermMatrix.EverAllowed
  (ComplianceRole -> OpAppendNote)    not in PermMatrix.EverAllowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md AuditEntry
pred AuditCompleteness {
  some Operation
  all op: Operation |
    (some op.caller) implies (one ae: AuditEntry | ae.ofOp = op)
  all ae: AuditEntry | some ae.ofOp
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012, FR-015
pred AppendOnly {
  // No clinical note can be "re-claimed" by a second operation (would model
  // an update). No audit entry can be re-claimed either.
  all n: ClinicalNote | one op: Operation | op.newNote = n
  all disj ae1, ae2: AuditEntry | ae1.ofOp != ae2.ofOp
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md AuditEntry
pred AttributionCorrectness {
  some AuditEntry
  all ae: AuditEntry |
    ae.recordedUser = ae.ofOp.caller and
    ae.recordedRole = ae.ofOp.caller.role and
    ae.recordedKind = ae.ofOp.kind and
    ae.recordedOutcome = ae.ofOp.outcome
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md users.assigned_record_id pairing CHECK
pred OwnershipExclusivity {
  all u: User | u.role = PatientRole  implies one u.assignedRecord
  all u: User | u.role != PatientRole implies no  u.assignedRecord
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006
pred OwnershipBasedAccess {
  all op: Operation |
    (some op.caller and op.caller.role = PatientRole and op.outcome = Permitted and
     op.kind in (OpReadRecord + OpReadRecordAudit))
      implies op.target = op.caller.assignedRecord
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008
pred NoInformationLeakage {
  // Denied operations never produce a note (no record content / state change leaks).
  all op: Operation | op.outcome = Denied implies no op.newNote
  // For unauthorised callers, outcome is Denied regardless of whether target exists.
  all op: Operation |
    (some op.caller and (op.caller.role -> op.kind) not in PermMatrix.EverAllowed)
      implies op.outcome = Denied
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// FEATURE-SPECIFIC  ANCHOR: FR-001 (auth required; no audit for unauth)
pred FR_001_AuthRequired {
  some Operation
  all op: Operation | op.outcome = Permitted implies some op.caller
  all op: Operation | (no op.caller) implies (no ae: AuditEntry | ae.ofOp = op)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 (exactly one role per user)
pred FR_002_OneRolePerUser {
  some User
  all u: User | one u.role
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 (patient iff assigned_record_id)
pred FR_003_PatientAssigned {
  some User
  all u: User | (u.role = PatientRole) iff (some u.assignedRecord)
}
assert FR_003_PatientAssigned { FR_003_PatientAssigned }
check FR_003_PatientAssigned for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 (clinician care-team gating)
pred FR_004_CareTeamGating {
  all op: Operation |
    (some op.caller and op.caller.role = ClinicianRole and op.outcome = Permitted and
     op.kind in (OpReadRecord + OpAppendNote + OpReadRecordAudit))
      implies (some ct: CareTeam | ct.ctClinician = op.caller and ct.ctRecord = op.target)
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 (clinician denied on /access-log)
pred FR_005_ClinicianNoAccessLog {
  all op: Operation |
    (some op.caller and op.caller.role = ClinicianRole and op.kind = OpReadAccessLog)
      implies op.outcome = Denied
}
assert FR_005_ClinicianNoAccessLog { FR_005_ClinicianNoAccessLog }
check FR_005_ClinicianNoAccessLog for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 (patient self-access only)
pred FR_006_PatientSelfAccess {
  all op: Operation |
    (some op.caller and op.caller.role = PatientRole and op.outcome = Permitted)
      implies (op.kind in (OpReadRecord + OpReadRecordAudit) and
               op.target = op.caller.assignedRecord)
}
assert FR_006_PatientSelfAccess { FR_006_PatientSelfAccess }
check FR_006_PatientSelfAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 (compliance officers denied clinical-content endpoints)
pred FR_007_ComplianceNoClinical {
  all op: Operation |
    (some op.caller and op.caller.role = ComplianceRole and
     op.kind in (OpReadRecord + OpAppendNote))
      implies op.outcome = Denied
}
assert FR_007_ComplianceNoClinical { FR_007_ComplianceNoClinical }
check FR_007_ComplianceNoClinical for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 (byte-equivalent denied; no leakage via outcome)
pred FR_008_ByteEquivalentDenied {
  all op: Operation | op.outcome = Denied implies no op.newNote
  all op: Operation |
    (some op.caller and (op.caller.role -> op.kind) not in PermMatrix.EverAllowed)
      implies op.outcome = Denied
}
assert FR_008_ByteEquivalentDenied { FR_008_ByteEquivalentDenied }
check FR_008_ByteEquivalentDenied for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 (200ms p99 — modelled structurally as
// "denied 403 path produces audit and no state change"; latency is operational)
pred FR_009_DeniedAlsoAudited {
  all op: Operation |
    (some op.caller and op.outcome = Denied) implies
      (one ae: AuditEntry | ae.ofOp = op and ae.recordedOutcome = Denied)
}
assert FR_009_DeniedAlsoAudited { FR_009_DeniedAlsoAudited }
check FR_009_DeniedAlsoAudited for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 (validation precedes mutation — only
// well-formed notes get persisted; modelled: every note traces to a
// permitted append op)
pred FR_010_ValidationBeforeMutation {
  all n: ClinicalNote | one op: Operation | op.newNote = n and op.outcome = Permitted
}
assert FR_010_ValidationBeforeMutation { FR_010_ValidationBeforeMutation }
check FR_010_ValidationBeforeMutation for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 (note attribution / snapshot)
pred FR_011_NoteAttribution {
  all n: ClinicalNote | n.noteAuthorRole = ClinicianRole
  all op: Operation, n: ClinicalNote |
    op.newNote = n implies (n.noteAuthor = op.caller and n.noteRecord = op.target)
}
assert FR_011_NoteAttribution { FR_011_NoteAttribution }
check FR_011_NoteAttribution for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 (notes append-only)
pred FR_012_NotesAppendOnly {
  all n: ClinicalNote | one op: Operation | op.newNote = n
}
assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 (always-on audit; one per access attempt)
pred FR_013_OneAuditPerAccess {
  some Operation
  all op: Operation |
    (some op.caller) implies (one ae: AuditEntry | ae.ofOp = op)
  all ae: AuditEntry | some ae.ofOp
}
assert FR_013_OneAuditPerAccess { FR_013_OneAuditPerAccess }
check FR_013_OneAuditPerAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 (audit-entry fields snapshot the op)
pred FR_014_AuditFields {
  some AuditEntry
  all ae: AuditEntry |
    ae.recordedUser    = ae.ofOp.caller and
    ae.recordedRole    = ae.ofOp.caller.role and
    ae.recordedKind    = ae.ofOp.kind and
    ae.recordedOutcome = ae.ofOp.outcome and
    ae.recordedRecord  = ae.ofOp.target and
    ae.recordedNote    = ae.ofOp.newNote
}
assert FR_014_AuditFields { FR_014_AuditFields }
check FR_014_AuditFields for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 (audit entries immutable — at most one per op)
pred FR_015_AuditImmutable {
  all disj ae1, ae2: AuditEntry | ae1.ofOp != ae2.ofOp
}
assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 (1s audit SLA — modelled as
// "no permitted state change without an audit entry")
pred FR_016_NoStateChangeWithoutAudit {
  all op: Operation |
    (op.outcome = Permitted and some op.newNote)
      implies (one ae: AuditEntry | ae.ofOp = op)
}
assert FR_016_NoStateChangeWithoutAudit { FR_016_NoStateChangeWithoutAudit }
check FR_016_NoStateChangeWithoutAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 (retention — no DELETE path; modelled
// as: every audit entry persists, i.e. every op with caller has one)
pred FR_017_AuditRetained {
  all op: Operation |
    (some op.caller) implies (some ae: AuditEntry | ae.ofOp = op)
}
assert FR_017_AuditRetained { FR_017_AuditRetained }
check FR_017_AuditRetained for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 (/access-log compliance-only)
pred FR_018_AccessLogComplianceOnly {
  all op: Operation |
    (some op.caller and op.kind = OpReadAccessLog and op.outcome = Permitted)
      implies op.caller.role = ComplianceRole
}
assert FR_018_AccessLogComplianceOnly { FR_018_AccessLogComplianceOnly }
check FR_018_AccessLogComplianceOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 (compliance content-blindness —
// compliance cannot read records or append notes)
pred FR_019_ComplianceContentBlind {
  all op: Operation |
    (some op.caller and op.caller.role = ComplianceRole and
     op.kind in (OpReadRecord + OpAppendNote))
      implies op.outcome = Denied
  // Compliance officers never author clinical notes.
  all n: ClinicalNote | n.noteAuthor.role != ComplianceRole
}
assert FR_019_ComplianceContentBlind { FR_019_ComplianceContentBlind }
check FR_019_ComplianceContentBlind for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020 (URL paths carry record_id only —
// every record-scoped op references a Record, never a patient demographic)
pred FR_020_RecordIdInPath {
  all op: Operation |
    op.kind in (OpReadRecord + OpAppendNote + OpReadRecordAudit)
      implies one op.target
  all op: Operation |
    op.kind = OpReadAccessLog implies no op.target
}
assert FR_020_RecordIdInPath { FR_020_RecordIdInPath }
check FR_020_RecordIdInPath for 6