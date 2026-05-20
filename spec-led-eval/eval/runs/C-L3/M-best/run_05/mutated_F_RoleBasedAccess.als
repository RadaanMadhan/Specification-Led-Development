// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===
// Feature: 013-hipaa-clinical-records (C-L3)
//
// Encodes the role/ownership permission matrix from contracts/http-api.md,
// the append-only / audit-completeness invariants from spec.md (FR-012,
// FR-013, FR-015), and the patient self-access + care-team gating rules
// (FR-004, FR-006).

// ---- Roles ---------------------------------------------------------------
abstract sig Role {}
one sig Clinician, Patient, ComplianceOfficer extends Role {}

// ---- Endpoints (operation kinds) -----------------------------------------
abstract sig OperationKind {}
one sig GetRecord, PostNote, GetRecordAudit, GetAccessLog extends OperationKind {}

// ---- Outcomes ------------------------------------------------------------
abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

// ---- Domain entities -----------------------------------------------------
sig Record {}

sig User {
  role: one Role,
  assignedRecord: lone Record    // populated iff role = Patient
}

sig CareTeamMembership {
  member: one User,
  forRecord: one Record
}

sig Operation {
  caller: one User,
  callerRole: one Role,          // snapshot of caller.role
  kind: one OperationKind,
  target: lone Record,           // none only for GetAccessLog
  outcome: one Outcome
}

sig ClinicalNote {
  noteRecord: one Record,
  author: one User,
  authorRoleSnap: one Role,      // snapshot of author.role at write time
  createdBy: one Operation       // the permitted PostNote op that created it
}

sig AuditEntry {
  forOp: one Operation,
  entryUser: one User,
  entryRole: one Role,
  entryRecord: lone Record,
  entryKind: one OperationKind,
  entryOutcome: one Outcome,
  entryNote: lone ClinicalNote
}

// Permission matrix lives on a singleton sig field (so we can mutate it
// and so that role->kind lookups are first-class).
one sig PermMatrix {
  MayAttempt: set Role -> OperationKind
}

// ====================================================================== //
//  Non-empty universe (so universals don't pass vacuously)                //
// ====================================================================== //
fact F_NonEmptyUniverse {
  some User
  some Record
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
  some Operation
}

// ====================================================================== //
//  Named facts — each is a mutation target                                //
// ====================================================================== //

// Permission matrix encoded from contracts/http-api.md.
fact F_PermissionMatrix {
  PermMatrix.MayAttempt =
      (Clinician         -> GetRecord)
    + (Clinician         -> PostNote)
    + (Clinician         -> GetRecordAudit)
    + (Patient           -> GetRecord)
    + (Patient           -> GetRecordAudit)
    + (ComplianceOfficer -> GetRecordAudit)
    + (ComplianceOfficer -> GetAccessLog)
}

// FR-003: only Patients carry assigned_record_id.
fact F_PatientAssignedRecord {
  all u: User | (u.role = Patient) iff (some u.assignedRecord)
}

// The caller's role on an operation is the caller's actual role.
fact F_CallerRoleSnapshot {
  all op: Operation | op.callerRole = op.caller.role
}

// GET /records/{id}, POST /records/{id}/notes, GET /records/{id}/audit
// carry a record_id; GET /access-log does not.
fact F_RecordScopedTarget {
  all op: Operation |
    (op.kind = GetRecord or op.kind = PostNote or op.kind = GetRecordAudit)
      implies some op.target
  all op: Operation |
    op.kind = GetAccessLog implies no op.target
}

// FR-004..FR-007 (role × endpoint cells): every permitted op corresponds
// to an allowed cell of the matrix.
fact F_RoleBasedAccess { /* MUTATED — body cleared by validator */ }

// FR-004: clinician access to a record requires active care-team membership.
fact F_ClinicianCareTeamGating {
  all op: Operation |
    (op.outcome = Permitted and op.callerRole = Clinician and
     (op.kind = GetRecord or op.kind = PostNote or op.kind = GetRecordAudit))
      implies (some m: CareTeamMembership |
                  m.member = op.caller and m.forRecord = op.target)
}

// FR-006: patient may only touch their own assigned_record_id.
fact F_PatientOwnRecord {
  all op: Operation |
    (op.outcome = Permitted and op.callerRole = Patient)
      implies op.caller.assignedRecord = op.target
}

// FR-013: every Operation has exactly one matching AuditEntry.
fact F_AuditPerOperation {
  all op: Operation | (one ae: AuditEntry | ae.forOp = op)
}

// FR-014: every AuditEntry field snapshots its Operation correctly.
fact F_AuditAttribution {
  all ae: AuditEntry |
    ae.entryUser    = ae.forOp.caller     and
    ae.entryRole    = ae.forOp.callerRole and
    ae.entryRecord  = ae.forOp.target     and
    ae.entryKind    = ae.forOp.kind       and
    ae.entryOutcome = ae.forOp.outcome
}

// FR-012: notes are append-only. Every note traces to exactly one permitted
// PostNote op, and no two notes share an originating op.
fact F_NotesOnlyFromPermittedAppend {
  all n: ClinicalNote |
    n.createdBy.kind = PostNote and n.createdBy.outcome = Permitted
  all disj n1, n2: ClinicalNote | n1.createdBy != n2.createdBy
}

// FR-011: note carries the author + record from its originating op, and
// author role is snapshotted as 'clinician'.
fact F_NoteLinksAndAuthor {
  all n: ClinicalNote |
    n.createdBy.caller = n.author and
    n.createdBy.target = n.noteRecord and
    n.author.role = Clinician and
    n.authorRoleSnap = Clinician
}

// FR-013 forward direction: every permitted PostNote op produces a note.
fact F_PermittedAppendHasNote {
  all op: Operation |
    (op.kind = PostNote and op.outcome = Permitted)
      implies (one n: ClinicalNote | n.createdBy = op)
  all op: Operation |
    (op.kind != PostNote or op.outcome != Permitted)
      implies (no n: ClinicalNote | n.createdBy = op)
}

// FR-014: audit's entryNote is set iff the op was a permitted append.
fact F_AuditNoteLink {
  all ae: AuditEntry |
    (ae.entryKind = PostNote and ae.entryOutcome = Permitted)
      implies (one n: ClinicalNote | n.createdBy = ae.forOp and ae.entryNote = n)
  all ae: AuditEntry |
    (ae.entryKind != PostNote or ae.entryOutcome != Permitted)
      implies no ae.entryNote
}

// FR-015: audit immutability — no two AuditEntries share an Operation.
fact F_AuditOneToOne {
  all disj a1, a2: AuditEntry | a1.forOp != a2.forOp
}

// ====================================================================== //
//  Predicates + assertions                                                //
// ====================================================================== //

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004..FR-007
pred LeastPrivilege {
  all op: Operation |
    op.outcome = Permitted implies (op.callerRole -> op.kind) in PermMatrix.MayAttempt
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Allowed cells must be present.
  (Clinician         -> GetRecord)       in PermMatrix.MayAttempt
  (Clinician         -> PostNote)        in PermMatrix.MayAttempt
  (Clinician         -> GetRecordAudit)  in PermMatrix.MayAttempt
  (Patient           -> GetRecord)       in PermMatrix.MayAttempt
  (Patient           -> GetRecordAudit)  in PermMatrix.MayAttempt
  (ComplianceOfficer -> GetRecordAudit)  in PermMatrix.MayAttempt
  (ComplianceOfficer -> GetAccessLog)    in PermMatrix.MayAttempt
  // Denied cells must be absent.
  (ComplianceOfficer -> GetRecord)       not in PermMatrix.MayAttempt
  (ComplianceOfficer -> PostNote)        not in PermMatrix.MayAttempt
  (Patient           -> PostNote)        not in PermMatrix.MayAttempt
  (Patient           -> GetAccessLog)    not in PermMatrix.MayAttempt
  (Clinician         -> GetAccessLog)    not in PermMatrix.MayAttempt
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004 (clinician care-team), FR-006 (patient owns assigned_record)
pred OwnershipBasedAccess {
  all op: Operation |
    (op.outcome = Permitted and op.callerRole = Clinician and
     (op.kind = GetRecord or op.kind = PostNote or op.kind = GetRecordAudit))
      implies (some m: CareTeamMembership |
                  m.member = op.caller and m.forRecord = op.target)
  all op: Operation |
    (op.outcome = Permitted and op.callerRole = Patient)
      implies op.caller.assignedRecord = op.target
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013 (exactly one audit per access)
pred AuditCompleteness {
  all op: Operation | (one ae: AuditEntry | ae.forOp = op)
  all ae: AuditEntry | some ae.forOp
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014 (audit fields match the operation)
pred AttributionCorrectness {
  all ae: AuditEntry |
    ae.entryUser    = ae.forOp.caller     and
    ae.entryRole    = ae.forOp.callerRole and
    ae.entryRecord  = ae.forOp.target     and
    ae.entryKind    = ae.forOp.kind       and
    ae.entryOutcome = ae.forOp.outcome
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012 (notes append-only), FR-015 (audit append-only)
pred AppendOnly {
  // Every clinical note originates from a permitted PostNote op.
  all n: ClinicalNote |
    n.createdBy.kind = PostNote and n.createdBy.outcome = Permitted
  // No two notes share an originating op.
  all disj n1, n2: ClinicalNote | n1.createdBy != n2.createdBy
  // No two audit entries share an op (audit-side immutability).
  all disj a1, a2: AuditEntry | a1.forOp != a2.forOp
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008 (denied response has no side effect)
pred NoInformationLeakage {
  // A denied operation never leaves a clinical note behind. The on-the-wire
  // byte-equivalence of the forbidden response is enforced by the absence
  // of any state change distinguishing "exists but denied" from "doesn't exist".
  all op: Operation |
    op.outcome = Denied implies (no n: ClinicalNote | n.createdBy = op)
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-010 (rejected requests cause no state mutation)
pred ValidationBeforeMutation {
  all op: Operation |
    op.outcome = Denied implies (no n: ClinicalNote | n.createdBy = op)
  all op: Operation |
    op.kind != PostNote implies (no n: ClinicalNote | n.createdBy = op)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md (patient ↔ exactly one assigned_record_id)
pred OwnershipExclusivity {
  all u: User | (u.role = Patient) iff (one u.assignedRecord)
  all u: User | (u.role != Patient) implies (no u.assignedRecord)
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// FEATURE-SPECIFIC  ANCHOR: FR-001 (authentication required; every op/audit ties to a User)
pred FR_001_AuthRequired {
  all op: Operation | some op.caller
  all ae: AuditEntry | some ae.entryUser
  all ae: AuditEntry | some ae.forOp
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 (single role per user)
pred FR_002_OneRolePerUser {
  all u: User | one u.role
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 (patient ↔ assigned_record_id pairing)
pred FR_003_PatientAssignedRecord {
  all u: User | (u.role = Patient) iff (some u.assignedRecord)
}
assert FR_003_PatientAssignedRecord { FR_003_PatientAssignedRecord }
check FR_003_PatientAssignedRecord for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 (clinician access requires active care-team membership)
pred FR_004_ClinicianCareTeamGating {
  all op: Operation |
    (op.outcome = Permitted and op.callerRole = Clinician and
     (op.kind = GetRecord or op.kind = PostNote or op.kind = GetRecordAudit))
      implies (some m: CareTeamMembership |
                  m.member = op.caller and m.forRecord = op.target)
}
assert FR_004_ClinicianCareTeamGating { FR_004_ClinicianCareTeamGating }
check FR_004_ClinicianCareTeamGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 (clinician cannot call GET /access-log)
pred FR_005_ClinicianNoAccessLog {
  all op: Operation |
    (op.callerRole = Clinician and op.kind = GetAccessLog)
      implies op.outcome = Denied
}
assert FR_005_ClinicianNoAccessLog { FR_005_ClinicianNoAccessLog }
check FR_005_ClinicianNoAccessLog for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 (patient may only access their own record; no notes; no access-log)
pred FR_006_PatientSelfAccessOnly {
  all op: Operation |
    (op.callerRole = Patient and op.outcome = Permitted and
     (op.kind = GetRecord or op.kind = GetRecordAudit))
      implies op.caller.assignedRecord = op.target
  all op: Operation |
    (op.callerRole = Patient and op.kind = PostNote) implies op.outcome = Denied
  all op: Operation |
    (op.callerRole = Patient and op.kind = GetAccessLog) implies op.outcome = Denied
}
assert FR_006_PatientSelfAccessOnly { FR_006_PatientSelfAccessOnly }
check FR_006_PatientSelfAccessOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 (compliance officer cannot read clinical content or append)
pred FR_007_ComplianceNoClinicalContent {
  all op: Operation |
    (op.callerRole = ComplianceOfficer and op.kind = GetRecord)
      implies op.outcome = Denied
  all op: Operation |
    (op.callerRole = ComplianceOfficer and op.kind = PostNote)
      implies op.outcome = Denied
}
assert FR_007_ComplianceNoClinicalContent { FR_007_ComplianceNoClinicalContent }
check FR_007_ComplianceNoClinicalContent for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 (denied responses produce no side effects revealing existence)
pred FR_008_NoLeakOnDeny {
  all op: Operation |
    op.outcome = Denied implies (no n: ClinicalNote | n.createdBy = op)
}
assert FR_008_NoLeakOnDeny { FR_008_NoLeakOnDeny }
check FR_008_NoLeakOnDeny for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 (note carries snapshotted author + role; only clinicians author)
pred FR_011_NoteAuthorSnapshot {
  all n: ClinicalNote |
    n.author.role = Clinician and
    n.authorRoleSnap = Clinician and
    n.createdBy.caller = n.author and
    n.createdBy.target = n.noteRecord
}
assert FR_011_NoteAuthorSnapshot { FR_011_NoteAuthorSnapshot }
check FR_011_NoteAuthorSnapshot for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 (clinical notes are append-only)
pred FR_012_NotesAppendOnly {
  all n: ClinicalNote |
    n.createdBy.kind = PostNote and n.createdBy.outcome = Permitted
  all disj n1, n2: ClinicalNote | n1.createdBy != n2.createdBy
}
assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 (exactly one audit entry per access event)
pred FR_013_OneAuditPerOp {
  all op: Operation | (one ae: AuditEntry | ae.forOp = op)
  all ae: AuditEntry | some ae.forOp
}
assert FR_013_OneAuditPerOp { FR_013_OneAuditPerOp }
check FR_013_OneAuditPerOp for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 (audit entry shape; note_id present iff permitted append)
pred FR_014_AuditShape {
  all ae: AuditEntry |
    ae.entryUser    = ae.forOp.caller     and
    ae.entryRole    = ae.forOp.callerRole and
    ae.entryRecord  = ae.forOp.target     and
    ae.entryKind    = ae.forOp.kind       and
    ae.entryOutcome = ae.forOp.outcome
  all ae: AuditEntry |
    (some ae.entryNote) iff (ae.entryKind = PostNote and ae.entryOutcome = Permitted)
}
assert FR_014_AuditShape { FR_014_AuditShape }
check FR_014_AuditShape for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 (audit entries immutable; 1:1 with operations)
pred FR_015_AuditImmutable {
  all disj a1, a2: AuditEntry | a1.forOp != a2.forOp
}
assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 (GET /access-log is compliance-officer-only; no record target)
pred FR_018_AccessLogComplianceOnly {
  all op: Operation |
    (op.kind = GetAccessLog and op.outcome = Permitted)
      implies op.callerRole = ComplianceOfficer
  all op: Operation |
    op.kind = GetAccessLog implies no op.target
}
assert FR_018_AccessLogComplianceOnly { FR_018_AccessLogComplianceOnly }
check FR_018_AccessLogComplianceOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 (compliance responses carry no clinical content;
// modeled as: compliance is never permitted on clinical-content endpoints)
pred FR_019_ComplianceContentBlind {
  all op: Operation |
    (op.callerRole = ComplianceOfficer and op.kind = GetRecord)
      implies op.outcome = Denied
  all op: Operation |
    (op.callerRole = ComplianceOfficer and op.kind = PostNote)
      implies op.outcome = Denied
}
assert FR_019_ComplianceContentBlind { FR_019_ComplianceContentBlind }
check FR_019_ComplianceContentBlind for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020 (only opaque record_id targets record-scoped endpoints;
// modeled as: every record-scoped op resolves to a single Record atom)
pred FR_020_OpaqueRecordTarget {
  all op: Operation |
    (op.kind = GetRecord or op.kind = PostNote or op.kind = GetRecordAudit)
      implies one op.target
  all op: Operation | op.kind = GetAccessLog implies no op.target
}
assert FR_020_OpaqueRecordTarget { FR_020_OpaqueRecordTarget }
check FR_020_OpaqueRecordTarget for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_LeastPrivilegeViolation { some op: Operation | op.callerRole = ComplianceOfficer and op.kind = GetRecord and op.outcome = Permitted }
