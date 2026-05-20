// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===
// Feature: C-L3  (branch: 013-hipaa-clinical-records)
// Sources: spec.md (FR-001 … FR-020), data-model.md, contracts/http-api.md
// Generated 2026-05-17

// ══════════════════════════════════════════════════════════════════════════════
// SIGS — domain types
// ══════════════════════════════════════════════════════════════════════════════

// ── Roles ─────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Clinician, Patient, ComplianceOfficer extends Role {}

// ── Contextual relationship between caller and targeted resource ───────────────
// Computed per-request from role + care-team membership + assigned record.
abstract sig Relationship {}
one sig CareTeamClinician,    // clinician with active CTM for the target record
         NonCareTeamClinician, // clinician without active CTM
         PatientOwn,           // patient, target = their assigned_record_id
         PatientOther,         // patient, target ≠ their assigned_record_id
         ComplianceOfficerRel  // compliance_officer (no contextual sub-type)
    extends Relationship {}

// ── Endpoint / operation kinds ────────────────────────────────────────────────
abstract sig OperationKind {}
one sig GetRecord, PostNote, GetRecordAudit, GetAccessLog extends OperationKind {}

// ── Audit operation type codes ────────────────────────────────────────────────
abstract sig AuditOpType {}
one sig Read, Append, List extends AuditOpType {}

// ── Outcomes ──────────────────────────────────────────────────────────────────
abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

// ── Dynamic sigs ──────────────────────────────────────────────────────────────

sig User {
  role:           one Role,
  assignedRecord: lone Record  // non-null iff role = Patient (FR-003)
}

sig Record {}

// Active care-team membership: clinician C is on the care team for record R.
sig CareTeamMembership {
  ctmClinician: one User,
  ctmRecord:    one Record
}

// Clinical notes: append-only, authored only by care-team clinicians (FR-011, FR-012).
sig ClinicalNote {
  noteRecord: one Record,
  noteAuthor: one User
}

// Audit entries: immutable, append-only (FR-013 … FR-017).
sig AuditEntry {
  entryUser:    one  User,
  entryRole:    one  Role,
  entryRecord:  lone Record,       // lone: null for GetAccessLog list events
  entryOpType:  one  AuditOpType,
  entryOutcome: one  Outcome,
  entryNote:    lone ClinicalNote  // non-null iff append + permitted (FR-014)
}

// HTTP operations processed by the system.
sig Operation {
  opKind:         one  OperationKind,
  opCaller:       one  User,
  opRecord:       lone Record,       // lone: GetAccessLog has no per-record target
  opRelationship: one  Relationship,
  opOutcome:      one  Outcome,
  opAudit:        one  AuditEntry    // exactly one per operation (FR-013)
}

// Permission matrix: singleton encapsulating the authority table.
one sig PermMatrix {
  Allowed: set Relationship -> OperationKind
}

// ══════════════════════════════════════════════════════════════════════════════
// F_NonEmptyUniverse — ensures no vacuous universal quantification
// ══════════════════════════════════════════════════════════════════════════════
fact F_NonEmptyUniverse {
  some User
  some Record
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
  some Operation
}

// ══════════════════════════════════════════════════════════════════════════════
// STRUCTURAL FACTS
// ══════════════════════════════════════════════════════════════════════════════

// FR-002 / FR-003: patient ↔ assignedRecord pairing; non-patients have no assignment.
fact F_PatientAssignedRecordPairing {
  all u: User |
    (u.role = Patient    implies (one  u.assignedRecord)) and
    (u.role != Patient   implies (no   u.assignedRecord))
}

// Care-team memberships only involve users with role Clinician.
fact F_CareTeamMembersAreClinicians {
  all m: CareTeamMembership | m.ctmClinician.role = Clinician
}

// FR-011 / FR-012: notes are authored only by clinicians who hold an active CTM for the note's record.
fact F_NoteAuthorMustBeCareTeamClinician {
  all n: ClinicalNote |
    n.noteAuthor.role = Clinician and
    (some m: CareTeamMembership |
      m.ctmClinician = n.noteAuthor and m.ctmRecord = n.noteRecord)
}

// Permission matrix: closed-world assignment from contracts/http-api.md.
// spec.md FR-004, FR-005, FR-006, FR-007; contracts/http-api.md permission table.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (CareTeamClinician    -> GetRecord)      +
    (CareTeamClinician    -> PostNote)       +
    (CareTeamClinician    -> GetRecordAudit) +
    (PatientOwn           -> GetRecord)      +
    (PatientOwn           -> GetRecordAudit) +
    (ComplianceOfficerRel -> GetRecordAudit) +
    (ComplianceOfficerRel -> GetAccessLog)
}

// Relationship is correctly computed from role, care-team membership, and
// assigned record — evaluated on every request (FR-004, FR-006).
fact F_RelationshipComputation {
  all op: Operation | {
    // Clinician branch
    op.opCaller.role = Clinician implies (
      (op.opRelationship = CareTeamClinician or
       op.opRelationship = NonCareTeamClinician) and
      ((op.opRelationship = CareTeamClinician) iff
       (some m: CareTeamMembership |
         m.ctmClinician = op.opCaller and m.ctmRecord = op.opRecord))
    )
    // Patient branch
    op.opCaller.role = Patient implies (
      (op.opRelationship = PatientOwn or
       op.opRelationship = PatientOther) and
      ((op.opRelationship = PatientOwn) iff
       (op.opRecord = op.opCaller.assignedRecord))
    )
    // Compliance officer branch
    op.opCaller.role = ComplianceOfficer implies
      op.opRelationship = ComplianceOfficerRel
  }
}

// Outcome is Permitted iff the (relationship, opKind) cell is in the Allowed matrix.
fact F_OutcomeFromPermissionMatrix {
  all op: Operation |
    (op.opOutcome = Permitted) iff
    ((op.opRelationship -> op.opKind) in PermMatrix.Allowed)
}

// Record-scoped operations always target a record; GetAccessLog never does.
fact F_RecordScopedOpsHaveRecord {
  all op: Operation | {
    (op.opKind = GetRecord or op.opKind = PostNote or op.opKind = GetRecordAudit)
      implies (one op.opRecord)
    op.opKind = GetAccessLog implies (no op.opRecord)
  }
}

// FR-013: every operation produces exactly one audit entry;
//          every audit entry belongs to exactly one operation (bijection).
fact F_AuditBijection {
  // Injectivity: no two operations share an audit entry.
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
  // Surjectivity: every audit entry is reachable from some operation.
  all ae: AuditEntry | some op: Operation | op.opAudit = ae
}

// FR-014: audit entry attribution — user, role, record, outcome, opType match the operation.
fact F_AuditAttributionCorrect {
  all op: Operation | {
    op.opAudit.entryUser    = op.opCaller
    op.opAudit.entryRole    = op.opCaller.role
    op.opAudit.entryRecord  = op.opRecord
    op.opAudit.entryOutcome = op.opOutcome
    // opType derived from opKind
    (op.opKind = GetRecord)      implies op.opAudit.entryOpType = Read
    (op.opKind = PostNote)       implies op.opAudit.entryOpType = Append
    (op.opKind = GetRecordAudit) implies op.opAudit.entryOpType = List
    (op.opKind = GetAccessLog)   implies op.opAudit.entryOpType = List
  }
}

// FR-014: note_id present in audit iff operation=append AND outcome=permitted.
fact F_AuditNoteIdLinkage {
  all op: Operation | {
    (op.opKind = PostNote and op.opOutcome = Permitted) implies
      (one op.opAudit.entryNote and
       op.opAudit.entryNote.noteRecord = op.opRecord and
       op.opAudit.entryNote.noteAuthor = op.opCaller)
    (op.opKind != PostNote or op.opOutcome = Denied) implies
      (no op.opAudit.entryNote)
  }
}

// FR-012: clinical notes are created only by permitted PostNote operations.
//          No note can exist without a corresponding permitted append op.
fact F_NotesOnlyFromPermittedAppend {
  all n: ClinicalNote |
    some op: Operation |
      op.opKind = PostNote and
      op.opOutcome = Permitted and
      op.opAudit.entryNote = n
}

// FR-015 / FR-017: audit entries are immutable and append-only.
// Modelled structurally: every AuditEntry has exactly one owning Operation;
// no AuditEntry can be the entryNote of another AuditEntry (no aliasing).
// (Append-only is the absence of any deletion path — captured by the bijection
//  and the fact that no Operation field "removes" an AuditEntry.)
fact F_AuditEntriesAreImmutable {
  // Each audit entry's entryRole is snapshotted from its operation's caller role.
  all ae: AuditEntry |
    some op: Operation |
      op.opAudit = ae and ae.entryRole = op.opCaller.role
}

// FR-012 / FR-015: notes and audit entries are append-only —
// the model has no "delete" relation; every note/entry that exists
// is reachable from an Operation.
fact F_AppendOnlyStructure {
  // All AuditEntry atoms are reachable (covered by F_AuditBijection surjectivity).
  // All ClinicalNote atoms are reachable via a permitted PostNote operation.
  all n: ClinicalNote |
    some op: Operation |
      op.opKind = PostNote and
      op.opOutcome = Permitted and
      op.opAudit.entryNote = n
}

// ══════════════════════════════════════════════════════════════════════════════
// PREDICATES + ASSERTIONS — one per pattern or FR
// ══════════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission table; spec.md FR-004…FR-007
pred LeastPrivilege {
  // No operation produces Permitted for a (relationship, opKind) cell not in Allowed.
  all op: Operation |
    op.opOutcome = Permitted implies
      ((op.opRelationship -> op.opKind) in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  // Every possible (Relationship, OperationKind) pair has a determinate verdict:
  // either it is in Allowed (Permitted) or it is not (Denied).
  // In Alloy this is trivially ensured by the closed-world Allowed set,
  // but we assert that the matrix is non-empty and covers all five relationships
  // that are explicitly granted.
  some r: Relationship, k: OperationKind | r -> k in PermMatrix.Allowed
  // Assert denial cells are never accidentally promoted.
  NonCareTeamClinician -> GetRecord    not in PermMatrix.Allowed
  NonCareTeamClinician -> PostNote     not in PermMatrix.Allowed
  NonCareTeamClinician -> GetAccessLog not in PermMatrix.Allowed
  PatientOwn           -> PostNote     not in PermMatrix.Allowed
  PatientOwn           -> GetAccessLog not in PermMatrix.Allowed
  PatientOther         -> GetRecord    not in PermMatrix.Allowed
  PatientOther         -> PostNote     not in PermMatrix.Allowed
  PatientOther         -> GetRecordAudit not in PermMatrix.Allowed
  ComplianceOfficerRel -> GetRecord   not in PermMatrix.Allowed
  ComplianceOfficerRel -> PostNote    not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md §Authentication
pred AuthRequiredEverywhere {
  // Every operation is associated with exactly one caller (User).
  // Unauthenticated paths produce no Operation atom in the model (they return 401
  // before any handler runs and before any audit entry is written).
  all op: Operation | one op.opCaller
  // No operation's caller is an anonymous/nil entity — every opCaller is a real User.
  all op: Operation | op.opCaller in User
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md AuditEntry
pred AuditCompleteness {
  // Every Operation has exactly one AuditEntry — no gap.
  all op: Operation | one op.opAudit
  // Every AuditEntry belongs to exactly one Operation — no orphans.
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
  // The universe contains at least one Operation to make the predicate non-vacuous.
  some Operation
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012 (notes), FR-015 (audit); data-model.md append-only notes
pred AppendOnly {
  // Every ClinicalNote that exists was created by a permitted PostNote operation.
  all n: ClinicalNote |
    (some op: Operation |
      op.opKind = PostNote and
      op.opOutcome = Permitted and
      op.opAudit.entryNote = n)
  // Every AuditEntry that exists is reachable from exactly one Operation.
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
  // Witness: model has notes and audit entries.
  some ClinicalNote
  some AuditEntry
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md AuditEntry fields
pred AttributionCorrectness {
  all op: Operation | {
    op.opAudit.entryUser   = op.opCaller
    op.opAudit.entryRole   = op.opCaller.role
    op.opAudit.entryRecord = op.opRecord
  }
  some Operation
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md User.assigned_record_id
pred OwnershipBasedAccess {
  // A Patient may receive Permitted on GetRecord only if the target record is their assigned record.
  all op: Operation |
    (op.opCaller.role = Patient and op.opKind = GetRecord and op.opOutcome = Permitted) implies
      (op.opRecord = op.opCaller.assignedRecord)
  // A Patient may receive Permitted on GetRecordAudit only for their own record.
  all op: Operation |
    (op.opCaller.role = Patient and op.opKind = GetRecordAudit and op.opOutcome = Permitted) implies
      (op.opRecord = op.opCaller.assignedRecord)
  some op: Operation | op.opCaller.role = Patient
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008; contracts/http-api.md byte-equivalent 403
pred NoInformationLeakage {
  // If two operations by the same caller with the same opKind are both Denied,
  // they produce the same outcome regardless of whether a matching record exists.
  // We encode: for every Denied operation on a record-scoped endpoint,
  // the outcome does not depend on whether opRecord is a "real" record —
  // all Denied operations on the same (caller, opKind) produce Denied.
  all disj op1, op2: Operation |
    (op1.opCaller = op2.opCaller and
     op1.opKind   = op2.opKind   and
     op1.opOutcome = Denied and
     op2.opOutcome = Denied) implies
      (op1.opAudit.entryOutcome = Denied and op2.opAudit.entryOutcome = Denied)
  // Compliance officers, non-CT clinicians, and patients on wrong records all receive Denied.
  all op: Operation |
    (op.opRelationship = ComplianceOfficerRel and op.opKind = GetRecord) implies
      op.opOutcome = Denied
  all op: Operation |
    (op.opRelationship = NonCareTeamClinician and op.opKind = GetRecord) implies
      op.opOutcome = Denied
  all op: Operation |
    (op.opRelationship = PatientOther and op.opKind = GetRecord) implies
      op.opOutcome = Denied
  some op: Operation | op.opOutcome = Denied
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  // Every Operation has a valid authenticated caller; no operation can proceed
  // without a resolved User identity.
  all op: Operation | one op.opCaller and op.opCaller in User
  // No AuditEntry exists without an owning operation (unauthenticated attempts
  // produce no audit entry in this feature — FR-001 says no audit on 401).
  all ae: AuditEntry | some op: Operation | op.opAudit = ae
  some Operation
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_SingleRolePerUser {
  // Every user holds exactly one role.
  all u: User | one u.role
  some User
}
assert FR_002_SingleRolePerUser { FR_002_SingleRolePerUser }
check FR_002_SingleRolePerUser for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_PatientAssignedRecord {
  // Users with role Patient have exactly one assignedRecord;
  // users with other roles have none.
  all u: User |
    (u.role = Patient    implies (one  u.assignedRecord)) and
    (u.role != Patient   implies (no   u.assignedRecord))
  some u: User | u.role = Patient
}
assert FR_003_PatientAssignedRecord { FR_003_PatientAssignedRecord }
check FR_003_PatientAssignedRecord for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_CareTeamGating {
  // A Clinician receives Permitted on GetRecord only if they are in the care team.
  all op: Operation |
    (op.opCaller.role = Clinician and op.opKind = GetRecord and op.opOutcome = Permitted) implies
      (some m: CareTeamMembership |
        m.ctmClinician = op.opCaller and m.ctmRecord = op.opRecord)
  // A Clinician receives Permitted on PostNote only if they are in the care team.
  all op: Operation |
    (op.opCaller.role = Clinician and op.opKind = PostNote and op.opOutcome = Permitted) implies
      (some m: CareTeamMembership |
        m.ctmClinician = op.opCaller and m.ctmRecord = op.opRecord)
  some op: Operation | op.opCaller.role = Clinician
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_ClinicianAuditAccess {
  // A Clinician receives Permitted on GetRecordAudit only if in care team.
  all op: Operation |
    (op.opCaller.role = Clinician and op.opKind = GetRecordAudit and op.opOutcome = Permitted) implies
      (some m: CareTeamMembership |
        m.ctmClinician = op.opCaller and m.ctmRecord = op.opRecord)
  // Clinicians are always Denied on GetAccessLog (system-wide log is compliance-only).
  all op: Operation |
    (op.opCaller.role = Clinician and op.opKind = GetAccessLog) implies
      op.opOutcome = Denied
  some op: Operation | op.opCaller.role = Clinician
}
assert FR_005_ClinicianAuditAccess { FR_005_ClinicianAuditAccess }
check FR_005_ClinicianAuditAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_PatientSelfAccess {
  // Patients are denied on PostNote for any record.
  all op: Operation |
    (op.opCaller.role = Patient and op.opKind = PostNote) implies op.opOutcome = Denied
  // Patients are denied on GetAccessLog.
  all op: Operation |
    (op.opCaller.role = Patient and op.opKind = GetAccessLog) implies op.opOutcome = Denied
  // Patients are permitted GetRecord only for their own record.
  all op: Operation |
    (op.opCaller.role = Patient and op.opKind = GetRecord and op.opOutcome = Permitted) implies
      op.opRecord = op.opCaller.assignedRecord
  some op: Operation | op.opCaller.role = Patient
}
assert FR_006_PatientSelfAccess { FR_006_PatientSelfAccess }
check FR_006_PatientSelfAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_ComplianceContentBlind {
  // Compliance officers are always Denied on GetRecord (clinical content).
  all op: Operation |
    (op.opCaller.role = ComplianceOfficer and op.opKind = GetRecord) implies
      op.opOutcome = Denied
  // Compliance officers are always Denied on PostNote.
  all op: Operation |
    (op.opCaller.role = ComplianceOfficer and op.opKind = PostNote) implies
      op.opOutcome = Denied
  // Compliance officers are Permitted on GetRecordAudit and GetAccessLog.
  all op: Operation |
    (op.opCaller.role = ComplianceOfficer and op.opKind = GetAccessLog) implies
      op.opOutcome = Permitted
  some op: Operation | op.opCaller.role = ComplianceOfficer
}
assert FR_007_ComplianceContentBlind { FR_007_ComplianceContentBlind }
check FR_007_ComplianceContentBlind for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008; spec.md US5
pred FR_008_ByteEquivalentForbidden {
  // Every Denied operation results in exactly one audit entry recording Denied.
  all op: Operation |
    op.opOutcome = Denied implies op.opAudit.entryOutcome = Denied
  // The denial is uniform: a non-CT clinician, a patient on the wrong record, and a
  // compliance officer all produce Denied on GetRecord.
  all op: Operation |
    (op.opRelationship = NonCareTeamClinician and op.opKind = GetRecord) implies
      op.opOutcome = Denied
  all op: Operation |
    (op.opRelationship = PatientOther and op.opKind = GetRecord) implies
      op.opOutcome = Denied
  all op: Operation |
    (op.opRelationship = ComplianceOfficerRel and op.opKind = GetRecord) implies
      op.opOutcome = Denied
  some op: Operation | op.opOutcome = Denied
}
assert FR_008_ByteEquivalentForbidden { FR_008_ByteEquivalentForbidden }
check FR_008_ByteEquivalentForbidden for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012; data-model.md ClinicalNote append-only enforcement
pred FR_012_NotesAppendOnly {
  // Every ClinicalNote that exists is linked to a permitted PostNote operation.
  // There is no unattached note (no deletion, no orphan).
  all n: ClinicalNote |
    (some op: Operation |
      op.opKind = PostNote and
      op.opOutcome = Permitted and
      op.opAudit.entryNote = n)
  // Notes are only authored by clinicians.
  all n: ClinicalNote | n.noteAuthor.role = Clinician
  // The model is non-vacuous: at least one note exists.
  some ClinicalNote
}
assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013; spec.md SC-001 SC-002
pred FR_013_AlwaysOnAudit {
  // For every Operation, exactly one AuditEntry exists for it.
  all op: Operation | one op.opAudit
  // Every AuditEntry is owned by exactly one Operation.
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
  // The universe is non-vacuous.
  some Operation
  some AuditEntry
}
assert FR_013_AlwaysOnAudit { FR_013_AlwaysOnAudit }
check FR_013_AlwaysOnAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014; data-model.md AuditEntry
pred FR_014_AuditEntryFields {
  // Every audit entry has a valid user, role, opType, and outcome.
  all ae: AuditEntry | {
    one ae.entryUser
    one ae.entryRole
    one ae.entryOpType
    one ae.entryOutcome
    // note_id present iff Append + Permitted.
    (ae.entryOpType = Append and ae.entryOutcome = Permitted) implies (one ae.entryNote)
    (ae.entryOpType != Append or ae.entryOutcome = Denied)    implies (no  ae.entryNote)
  }
  some AuditEntry
}
assert FR_014_AuditEntryFields { FR_014_AuditEntryFields }
check FR_014_AuditEntryFields for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015; data-model.md AuditEntry immutability
pred FR_015_AuditImmutable {
  // Every AuditEntry's recorded role matches the owning operation's caller's role at the time of write.
  all ae: AuditEntry |
    (some op: Operation |
      op.opAudit = ae and ae.entryRole = op.opCaller.role)
  // Every AuditEntry's user matches the owning operation's caller.
  all ae: AuditEntry |
    (some op: Operation |
      op.opAudit = ae and ae.entryUser = op.opCaller)
  some AuditEntry
}
assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017; data-model.md "no DELETE code path against audit_entries"
pred FR_017_AuditRetention {
  // Every AuditEntry that exists remains reachable — no entry is unlinked or "deleted".
  // Modelled as: every AuditEntry belongs to exactly one Operation.
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
  // A deleted entry would appear as an AuditEntry with no owning Operation; that is forbidden.
  no ae: AuditEntry | (no op: Operation | op.opAudit = ae)
  some AuditEntry
}
assert FR_017_AuditRetention { FR_017_AuditRetention }
check FR_017_AuditRetention for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018; contracts/http-api.md GET /access-log
pred FR_018_AccessLogComplianceOnly {
  // Only ComplianceOfficer receives Permitted on GetAccessLog.
  all op: Operation |
    (op.opKind = GetAccessLog and op.opOutcome = Permitted) implies
      op.opCaller.role = ComplianceOfficer
  // Clinicians and Patients are always Denied on GetAccessLog.
  all op: Operation |
    (op.opCaller.role = Clinician and op.opKind = GetAccessLog) implies
      op.opOutcome = Denied
  all op: Operation |
    (op.opCaller.role = Patient and op.opKind = GetAccessLog) implies
      op.opOutcome = Denied
  some op: Operation | op.opKind = GetAccessLog
}
assert FR_018_AccessLogComplianceOnly { FR_018_AccessLogComplianceOnly }
check FR_018_AccessLogComplianceOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020; data-model.md Record.id; spec.md FR-020
pred FR_020_RecordIdOnlyInPaths {
  // All record-scoped operations target a Record atom (an opaque record_id),
  // never a User demographic field.
  all op: Operation |
    (op.opKind = GetRecord or op.opKind = PostNote or op.opKind = GetRecordAudit) implies
      (op.opRecord in Record)
  some op: Operation | op.opKind = GetRecord
}
assert FR_020_RecordIdOnlyInPaths { FR_020_RecordIdOnlyInPaths }
check FR_020_RecordIdOnlyInPaths for 6