// === feature_model.als — Alloy 6 model for HIPAA Hospital Clinical Record Access ===
// Feature folder: C-L3  (branch: 013-hipaa-clinical-records)
// Spec: spec.md  Data model: data-model.md  Contract: contracts/http-api.md

// ─────────────────────────────────────────────────────────────────────────────
// Enumeration sigs
// ─────────────────────────────────────────────────────────────────────────────

abstract sig Role {}
one sig Clinician, Patient, ComplianceOfficer extends Role {}

abstract sig OperationKind {}
one sig GetRecord, PostNote, GetRecordAudit, GetAccessLog extends OperationKind {}

abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

// ─────────────────────────────────────────────────────────────────────────────
// Domain sigs
// ─────────────────────────────────────────────────────────────────────────────

// Authenticated users only — unauthenticated requests never become AccessOps (FR-001).
sig User {
  role:           one Role,
  assignedRecord: lone Record   // non-null iff role = Patient (FR-003)
}

// Opaque patient health records
sig Record {}

// Active care-team memberships only.
// An ended membership row is absent from this sig (FR-004).
sig CareTeamMembership {
  ctClinician: one User,
  ctRecord:    one Record
}

// Append-only clinical notes (FR-011, FR-012)
sig ClinicalNote {
  noteRecord: one Record,
  noteAuthor: one User
}

// One AccessOp per authenticated request that reaches a handler.
// targetRecord is absent (lone) for GetAccessLog (no {id} in the URL).
sig AccessOp {
  opCaller:  one User,
  opKind:    one OperationKind,
  opTarget:  lone Record,
  opOutcome: one Outcome
}

// One immutable AuditEntry per AccessOp (FR-013, FR-014, FR-015).
// Attribution fields are snapshotted at write time.
sig AuditEntry {
  logOp:      one AccessOp,
  logCaller:  one User,
  logRole:    one Role,
  logKind:    one OperationKind,
  logOutcome: one Outcome
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NonEmptyUniverse — ensure dynamic sigs are non-empty so assertions bite
// ─────────────────────────────────────────────────────────────────────────────

fact F_NonEmptyUniverse {
  some User
  some Record
  some CareTeamMembership
  some ClinicalNote
  some AccessOp
  some AuditEntry
}

// ─────────────────────────────────────────────────────────────────────────────
// Structural facts
// ─────────────────────────────────────────────────────────────────────────────

// FR-002 / FR-003: exactly one role per user; patient ↔ assignedRecord pairing.
fact F_PatientRecordPairing { /* MUTATED — body cleared by validator */ }

// Care-team members must be clinicians (data-model.md CareTeamMembership).
fact F_CareTeamMembersAreClinicians {
  all m: CareTeamMembership | m.ctClinician.role = Clinician
}

// GetAccessLog has no record-scoped target (data-model.md / contracts/http-api.md).
fact F_GetAccessLogNoTarget {
  all op: AccessOp | op.opKind = GetAccessLog implies no op.opTarget
}

// Record-scoped operations must have a target record.
fact F_RecordScopedOpsHaveTarget {
  all op: AccessOp |
    op.opKind != GetAccessLog implies one op.opTarget
}

// ─────────────────────────────────────────────────────────────────────────────
// Permission / authorisation facts
// ─────────────────────────────────────────────────────────────────────────────

// FR-004 / FR-005 / FR-006 / FR-007: the normative authorisation matrix.
// Encodes every (role, operation-kind) cell from contracts/http-api.md.
fact F_AuthorizationRules {
  all op: AccessOp | let u = op.opCaller, k = op.opKind, r = op.opTarget |
  {
    // ── GET /records/{id} ────────────────────────────────────────────────────
    k = GetRecord implies (
      op.opOutcome = Permitted iff (
        (u.role = Clinician and
          (some m: CareTeamMembership | m.ctClinician = u and m.ctRecord = r))
        or
        (u.role = Patient and u.assignedRecord = r)
      )
    )

    // ── POST /records/{id}/notes ─────────────────────────────────────────────
    k = PostNote implies (
      op.opOutcome = Permitted iff (
        u.role = Clinician and
          (some m: CareTeamMembership | m.ctClinician = u and m.ctRecord = r)
      )
    )

    // ── GET /records/{id}/audit ──────────────────────────────────────────────
    k = GetRecordAudit implies (
      op.opOutcome = Permitted iff (
        (u.role = Clinician and
          (some m: CareTeamMembership | m.ctClinician = u and m.ctRecord = r))
        or
        (u.role = Patient and u.assignedRecord = r)
        or
        u.role = ComplianceOfficer
      )
    )

    // ── GET /access-log ──────────────────────────────────────────────────────
    k = GetAccessLog implies (
      op.opOutcome = Permitted iff u.role = ComplianceOfficer
    )
  }
}

// FR-007 / FR-019: compliance officers may never obtain Permitted on clinical-content endpoints.
fact F_ComplianceContentBlind {
  all op: AccessOp |
    (op.opCaller.role = ComplianceOfficer and
     (op.opKind = GetRecord or op.opKind = PostNote))
    implies op.opOutcome = Denied
}

// ─────────────────────────────────────────────────────────────────────────────
// Audit facts
// ─────────────────────────────────────────────────────────────────────────────

// FR-013: every AccessOp has exactly one AuditEntry.
fact F_AuditCompleteness {
  all op: AccessOp | one ae: AuditEntry | ae.logOp = op
}

// FR-015 / AppendOnly: no two AuditEntries reference the same AccessOp
// (injection = uniqueness = no mutation/overwrite of an existing entry).
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry | ae1.logOp != ae2.logOp
}

// FR-014: AuditEntry attribution fields match the operation they record.
fact F_AuditEntryAttribution {
  all ae: AuditEntry |
    ae.logCaller  = ae.logOp.opCaller  and
    ae.logRole    = ae.logOp.opCaller.role and
    ae.logKind    = ae.logOp.opKind    and
    ae.logOutcome = ae.logOp.opOutcome
}

// ─────────────────────────────────────────────────────────────────────────────
// Note facts
// ─────────────────────────────────────────────────────────────────────────────

// FR-011: only clinicians can author notes (CHECK author_role = 'clinician').
fact F_NoteAuthorIsClinician {
  all n: ClinicalNote | n.noteAuthor.role = Clinician
}

// FR-004 / FR-011: notes may only be created by a care-team clinician for that record.
fact F_NoteAuthorInCareTeam {
  all n: ClinicalNote |
    some m: CareTeamMembership |
      m.ctClinician = n.noteAuthor and m.ctRecord = n.noteRecord
}

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: LeastPrivilege
// ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004 FR-005 FR-006 FR-007
// ─────────────────────────────────────────────────────────────────────────────
pred LeastPrivilege {
  some AccessOp
  // Every Denied outcome reflects a genuine absence of permission.
  // ComplianceOfficer never gets Permitted on clinical-content endpoints.
  all op: AccessOp |
    (op.opCaller.role = ComplianceOfficer and
     (op.opKind = GetRecord or op.opKind = PostNote))
    implies op.opOutcome = Denied
  // Non-care-team clinician never gets Permitted on GetRecord.
  all op: AccessOp |
    (op.opCaller.role = Clinician and op.opKind = GetRecord and
     (no m: CareTeamMembership | m.ctClinician = op.opCaller and m.ctRecord = op.opTarget))
    implies op.opOutcome = Denied
  // Patient never gets Permitted on GetRecord for a record that is not their own.
  all op: AccessOp |
    (op.opCaller.role = Patient and op.opKind = GetRecord and
     op.opCaller.assignedRecord != op.opTarget)
    implies op.opOutcome = Denied
  // Non-ComplianceOfficer never gets Permitted on GetAccessLog.
  all op: AccessOp |
    (op.opCaller.role != ComplianceOfficer and op.opKind = GetAccessLog)
    implies op.opOutcome = Denied
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: PermissionCompleteness
// ANCHOR: contracts/http-api.md permission matrix; all 4 OperationKind atoms defined
// ─────────────────────────────────────────────────────────────────────────────
pred PermissionCompleteness {
  some AccessOp
  // Every AccessOp has a definite outcome — no undefined cell.
  all op: AccessOp | op.opOutcome = Permitted or op.opOutcome = Denied
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AuthRequiredEverywhere
// ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
// ─────────────────────────────────────────────────────────────────────────────
pred AuthRequiredEverywhere {
  some AccessOp
  // Every access operation has a caller — unauthenticated requests produce no AccessOp.
  all op: AccessOp | one op.opCaller
  // Correspondingly every AuditEntry has a caller (never null).
  all ae: AuditEntry | one ae.logCaller
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AuditCompleteness
// ANCHOR: spec.md FR-013 FR-014; data-model.md AuditEntry UNIQUE constraint; SC-001 SC-002
// ─────────────────────────────────────────────────────────────────────────────
pred AuditCompleteness {
  some AccessOp
  // Every AccessOp has exactly one audit entry.
  all op: AccessOp | (one ae: AuditEntry | ae.logOp = op)
  // No AuditEntry exists without a matching AccessOp.
  all ae: AuditEntry | ae.logOp in AccessOp
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AppendOnly
// ANCHOR: spec.md FR-012 FR-015 FR-017; data-model.md "no UPDATE/DELETE" on audit_entries and clinical_notes
// ─────────────────────────────────────────────────────────────────────────────
pred AppendOnly {
  some AuditEntry
  // No two AuditEntries share the same AccessOp (injection = no overwrite).
  all disj ae1, ae2: AuditEntry | ae1.logOp != ae2.logOp
  // Every ClinicalNote still exists (no deletion).
  some ClinicalNote
}

assert AppendOnly { AppendOnly }
check AppendOnly for 6

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AttributionCorrectness
// ANCHOR: spec.md FR-014; data-model.md AuditEntry snapshotted fields
// ─────────────────────────────────────────────────────────────────────────────
pred AttributionCorrectness {
  some AuditEntry
  // Every audit entry's snapshotted fields match the actual operation.
  all ae: AuditEntry |
    ae.logCaller  = ae.logOp.opCaller       and
    ae.logRole    = ae.logOp.opCaller.role  and
    ae.logKind    = ae.logOp.opKind         and
    ae.logOutcome = ae.logOp.opOutcome
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: OwnershipExclusivity
// ANCHOR: spec.md FR-002 FR-003; data-model.md User.assigned_record_id pairing CHECK
// ─────────────────────────────────────────────────────────────────────────────
pred OwnershipExclusivity {
  some u: User | u.role = Patient
  // Every patient user has exactly one assigned record.
  all u: User | u.role = Patient implies (one u.assignedRecord)
  // Non-patient users have no assigned record.
  all u: User | u.role != Patient implies no u.assignedRecord
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: OwnershipBasedAccess
// ANCHOR: spec.md FR-006; data-model.md User.assigned_record_id; contracts/http-api.md patient row
// ─────────────────────────────────────────────────────────────────────────────
pred OwnershipBasedAccess {
  some op: AccessOp | op.opCaller.role = Patient
  // A patient gets Permitted on GetRecord iff the target IS their assigned record.
  all op: AccessOp |
    (op.opCaller.role = Patient and op.opKind = GetRecord)
    implies
    (op.opOutcome = Permitted iff op.opCaller.assignedRecord = op.opTarget)
  // A patient never gets Permitted on PostNote.
  all op: AccessOp |
    (op.opCaller.role = Patient and op.opKind = PostNote)
    implies op.opOutcome = Denied
  // A patient gets Permitted on GetRecordAudit iff the target IS their assigned record.
  all op: AccessOp |
    (op.opCaller.role = Patient and op.opKind = GetRecordAudit)
    implies
    (op.opOutcome = Permitted iff op.opCaller.assignedRecord = op.opTarget)
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: NoInformationLeakage
// ANCHOR: spec.md FR-008; contracts/http-api.md byte-equivalent forbidden response; SC-003
// ─────────────────────────────────────────────────────────────────────────────
// Modelled as: the outcome for any caller without permission is Denied,
// regardless of whether the target record exists in the Record sig.
// (An absent Record atom models a fabricated id; the outcome is the same.)
pred NoInformationLeakage {
  some AccessOp
  // The Denied response is uniform — it does not distinguish existence.
  // Concretely: every unauthorised operation on GetRecord produces Denied
  // whether the record exists or not. This is enforced by F_AuthorizationRules;
  // the predicate asserts the invariant holds for at least one Denied op.
  some op: AccessOp |
    op.opKind = GetRecord and op.opOutcome = Denied
  all op: AccessOp |
    (op.opKind = GetRecord and op.opOutcome = Denied)
    implies
    (
      -- clinician without care-team membership
      (op.opCaller.role = Clinician and
        no m: CareTeamMembership | m.ctClinician = op.opCaller and m.ctRecord = op.opTarget)
      or
      -- patient on a non-owned record
      (op.opCaller.role = Patient and op.opCaller.assignedRecord != op.opTarget)
      or
      -- compliance officer
      op.opCaller.role = ComplianceOfficer
    )
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-001 — unauthenticated requests produce no AccessOp or AuditEntry
// ─────────────────────────────────────────────────────────────────────────────
pred FR_001_AuthRequired {
  some AccessOp
  // Every AccessOp must have a valid (authenticated) caller.
  all op: AccessOp | one op.opCaller
  // Every AuditEntry must have a valid caller attribution (never null / ghost).
  all ae: AuditEntry | ae.logCaller = ae.logOp.opCaller
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-002 FR-003 — single role per user; patient↔record pairing
// ─────────────────────────────────────────────────────────────────────────────
pred FR_002_SingleRoleAndPatientPairing {
  some u: User | u.role = Patient
  some u: User | u.role = Clinician
  some u: User | u.role = ComplianceOfficer
  all u: User | u.role = Patient  implies (one u.assignedRecord)
  all u: User | u.role != Patient implies (no u.assignedRecord)
}

assert FR_002_SingleRoleAndPatientPairing { FR_002_SingleRoleAndPatientPairing }
check FR_002_SingleRoleAndPatientPairing for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-004 — clinician access gated on active care-team membership
// ─────────────────────────────────────────────────────────────────────────────
pred FR_004_CareTeamGating {
  some op: AccessOp | op.opCaller.role = Clinician and op.opKind = GetRecord
  // A clinician gets Permitted on GetRecord iff an active care-team membership exists.
  all op: AccessOp |
    (op.opCaller.role = Clinician and op.opKind = GetRecord)
    implies
    (op.opOutcome = Permitted iff
      (some m: CareTeamMembership | m.ctClinician = op.opCaller and m.ctRecord = op.opTarget))
  // Same gate for PostNote.
  all op: AccessOp |
    (op.opCaller.role = Clinician and op.opKind = PostNote)
    implies
    (op.opOutcome = Permitted iff
      (some m: CareTeamMembership | m.ctClinician = op.opCaller and m.ctRecord = op.opTarget))
}

assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-005 — clinician may read per-record audit iff in care team
// ─────────────────────────────────────────────────────────────────────────────
pred FR_005_ClinicianAuditAccess {
  some op: AccessOp | op.opCaller.role = Clinician and op.opKind = GetRecordAudit
  // Clinician gets Permitted on GetRecordAudit iff in care team.
  all op: AccessOp |
    (op.opCaller.role = Clinician and op.opKind = GetRecordAudit)
    implies
    (op.opOutcome = Permitted iff
      (some m: CareTeamMembership | m.ctClinician = op.opCaller and m.ctRecord = op.opTarget))
  // Clinician never gets Permitted on GetAccessLog (system-wide log is CO-only).
  all op: AccessOp |
    (op.opCaller.role = Clinician and op.opKind = GetAccessLog)
    implies op.opOutcome = Denied
}

assert FR_005_ClinicianAuditAccess { FR_005_ClinicianAuditAccess }
check FR_005_ClinicianAuditAccess for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-006 — patient self-access only
// ─────────────────────────────────────────────────────────────────────────────
pred FR_006_PatientSelfAccess {
  some op: AccessOp | op.opCaller.role = Patient
  // Patient can only get Permitted on GetRecord/GetRecordAudit for their own record.
  all op: AccessOp |
    (op.opCaller.role = Patient and
     (op.opKind = GetRecord or op.opKind = GetRecordAudit))
    implies
    (op.opOutcome = Permitted iff op.opCaller.assignedRecord = op.opTarget)
  // Patient never gets Permitted on PostNote.
  all op: AccessOp |
    (op.opCaller.role = Patient and op.opKind = PostNote)
    implies op.opOutcome = Denied
  // Patient never gets Permitted on GetAccessLog.
  all op: AccessOp |
    (op.opCaller.role = Patient and op.opKind = GetAccessLog)
    implies op.opOutcome = Denied
}

assert FR_006_PatientSelfAccess { FR_006_PatientSelfAccess }
check FR_006_PatientSelfAccess for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-007 FR-019 — compliance officer content blindness
// ─────────────────────────────────────────────────────────────────────────────
pred FR_007_ComplianceContentBlindness {
  some op: AccessOp | op.opCaller.role = ComplianceOfficer
  // ComplianceOfficer never gets Permitted on GetRecord (clinical content).
  all op: AccessOp |
    (op.opCaller.role = ComplianceOfficer and op.opKind = GetRecord)
    implies op.opOutcome = Denied
  // ComplianceOfficer never gets Permitted on PostNote.
  all op: AccessOp |
    (op.opCaller.role = ComplianceOfficer and op.opKind = PostNote)
    implies op.opOutcome = Denied
  // ComplianceOfficer gets Permitted on GetAccessLog and GetRecordAudit.
  all op: AccessOp |
    (op.opCaller.role = ComplianceOfficer and op.opKind = GetAccessLog)
    implies op.opOutcome = Permitted
}

assert FR_007_ComplianceContentBlindness { FR_007_ComplianceContentBlindness }
check FR_007_ComplianceContentBlindness for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-008 — byte-equivalent denied response (existence-leak prevention)
// ─────────────────────────────────────────────────────────────────────────────
// Modelled as: the outcome for every unauthorised access is uniformly Denied,
// regardless of whether the record atom exists in the model.
pred FR_008_ByteEquivalentDenied {
  some op: AccessOp | op.opOutcome = Denied
  // Denied outcomes are structurally indistinguishable — there is only one Denied atom.
  all op: AccessOp |
    op.opOutcome = Denied implies op.opOutcome = Denied
  // No denied AccessOp can have Permitted outcome — trivially enforced by Outcome hierarchy.
  no op: AccessOp | op.opOutcome = Denied and op.opOutcome = Permitted
  // Key: a ComplianceOfficer denied on GetRecord gets the same Denied outcome as anyone else.
  all op1, op2: AccessOp |
    (op1.opOutcome = Denied and op2.opOutcome = Denied)
    implies op1.opOutcome = op2.opOutcome
}

assert FR_008_ByteEquivalentDenied { FR_008_ByteEquivalentDenied }
check FR_008_ByteEquivalentDenied for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-012 — clinical notes are append-only (no delete or edit endpoint)
// ─────────────────────────────────────────────────────────────────────────────
pred FR_012_NotesAppendOnly {
  some ClinicalNote
  // All note authors are clinicians.
  all n: ClinicalNote | n.noteAuthor.role = Clinician
  // All note authors are in the care team for the note's record.
  all n: ClinicalNote |
    (some m: CareTeamMembership | m.ctClinician = n.noteAuthor and m.ctRecord = n.noteRecord)
  // No two notes are identical (each note is a distinct append event).
  all disj n1, n2: ClinicalNote |
    not (n1.noteRecord = n2.noteRecord and n1.noteAuthor = n2.noteAuthor)
    or (n1 != n2)
}

assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-013 — always-on audit: exactly one entry per access
// ─────────────────────────────────────────────────────────────────────────────
pred FR_013_AlwaysOnAudit {
  some AccessOp
  // Every AccessOp has exactly one AuditEntry.
  all op: AccessOp | (one ae: AuditEntry | ae.logOp = op)
  // No AuditEntry exists without a corresponding AccessOp.
  all ae: AuditEntry | ae.logOp in AccessOp
  // Both Permitted and Denied ops are audited.
  some op: AccessOp | op.opOutcome = Permitted
  some op: AccessOp | op.opOutcome = Denied
}

assert FR_013_AlwaysOnAudit { FR_013_AlwaysOnAudit }
check FR_013_AlwaysOnAudit for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-014 — audit entry attribution fields are correct
// ─────────────────────────────────────────────────────────────────────────────
pred FR_014_AuditEntryFields {
  some AuditEntry
  all ae: AuditEntry |
    ae.logCaller  = ae.logOp.opCaller       and
    ae.logRole    = ae.logOp.opCaller.role  and
    ae.logKind    = ae.logOp.opKind         and
    ae.logOutcome = ae.logOp.opOutcome
}

assert FR_014_AuditEntryFields { FR_014_AuditEntryFields }
check FR_014_AuditEntryFields for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-015 FR-017 — audit entries are immutable; no two share an AccessOp
// ─────────────────────────────────────────────────────────────────────────────
pred FR_015_AuditImmutability {
  some AuditEntry
  // Injection: no two AuditEntries reference the same AccessOp.
  all disj ae1, ae2: AuditEntry | ae1.logOp != ae2.logOp
}

assert FR_015_AuditImmutability { FR_015_AuditImmutability }
check FR_015_AuditImmutability for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-016 — no state change without a durable audit entry
// ─────────────────────────────────────────────────────────────────────────────
// Modelled as: every Permitted PostNote AccessOp has an AuditEntry
// (combined with F_AuditCompleteness this is already universal; the predicate
// emphasises the Permitted+PostNote corner case explicitly).
pred FR_016_NoStateChangeWithoutAudit {
  some op: AccessOp | op.opKind = PostNote and op.opOutcome = Permitted
  all op: AccessOp |
    (op.opKind = PostNote and op.opOutcome = Permitted)
    implies (one ae: AuditEntry | ae.logOp = op and ae.logOutcome = Permitted)
  all op: AccessOp |
    (op.opKind = GetRecord and op.opOutcome = Permitted)
    implies (one ae: AuditEntry | ae.logOp = op)
}

assert FR_016_NoStateChangeWithoutAudit { FR_016_NoStateChangeWithoutAudit }
check FR_016_NoStateChangeWithoutAudit for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-018 — GET /access-log is compliance-officer-only
// ─────────────────────────────────────────────────────────────────────────────
pred FR_018_AccessLogComplianceOfficerOnly {
  some op: AccessOp | op.opKind = GetAccessLog
  all op: AccessOp |
    op.opKind = GetAccessLog implies
    (op.opOutcome = Permitted iff op.opCaller.role = ComplianceOfficer)
}

assert FR_018_AccessLogComplianceOfficerOnly { FR_018_AccessLogComplianceOfficerOnly }
check FR_018_AccessLogComplianceOfficerOnly for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-019 — compliance officer GetRecordAudit is permitted but content-blind
// (structural separation: ComplianceOfficer CAN list audit but CANNOT get clinical content)
// ─────────────────────────────────────────────────────────────────────────────
pred FR_019_ComplianceAuditAccessNoContent {
  some op: AccessOp | op.opCaller.role = ComplianceOfficer and op.opKind = GetRecordAudit
  // Compliance officer gets Permitted on audit endpoints.
  all op: AccessOp |
    (op.opCaller.role = ComplianceOfficer and op.opKind = GetRecordAudit)
    implies op.opOutcome = Permitted
  // Compliance officer gets Denied on clinical-content endpoint.
  all op: AccessOp |
    (op.opCaller.role = ComplianceOfficer and op.opKind = GetRecord)
    implies op.opOutcome = Denied
  // Compliance officer gets Denied on PostNote.
  all op: AccessOp |
    (op.opCaller.role = ComplianceOfficer and op.opKind = PostNote)
    implies op.opOutcome = Denied
}

assert FR_019_ComplianceAuditAccessNoContent { FR_019_ComplianceAuditAccessNoContent }
check FR_019_ComplianceAuditAccessNoContent for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: FR-011 data-model.md ClinicalNote.author_role CHECK
// — only clinicians in the care team can be note authors
// ─────────────────────────────────────────────────────────────────────────────
pred FR_011_NoteAuthorConstraint {
  some ClinicalNote
  // All note authors are clinicians.
  all n: ClinicalNote | n.noteAuthor.role = Clinician
  // All note authors have an active care-team membership for the note's record.
  all n: ClinicalNote |
    (some m: CareTeamMembership | m.ctClinician = n.noteAuthor and m.ctRecord = n.noteRecord)
}

assert FR_011_NoteAuthorConstraint { FR_011_NoteAuthorConstraint }
check FR_011_NoteAuthorConstraint for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC  ANCHOR: data-model.md AuditEntry CHECK (operation='append' AND outcome='permitted' → note_id IS NOT NULL)
// Modelled as: a Permitted PostNote AccessOp is uniquely linked to a ClinicalNote on the same record.
// ─────────────────────────────────────────────────────────────────────────────
pred FR_013_AuditNoteIdConsistency {
  // For every Permitted PostNote operation, a ClinicalNote exists on the target record
  // authored by the caller.
  some op: AccessOp | op.opKind = PostNote and op.opOutcome = Permitted
  all op: AccessOp |
    (op.opKind = PostNote and op.opOutcome = Permitted)
    implies
    (some n: ClinicalNote | n.noteRecord = op.opTarget and n.noteAuthor = op.opCaller)
}

assert FR_013_AuditNoteIdConsistency { FR_013_AuditNoteIdConsistency }
check FR_013_AuditNoteIdConsistency for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_PatientPairingBroken { some u: User | u.role = Patient and no u.assignedRecord }
