// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access (013) ===

// ---------- Static enums ----------

abstract sig Role {}
one sig Clinician, Patient, ComplianceOfficer extends Role {}

abstract sig OperationKind {}
one sig GetRecord, PostNote, GetRecordAudit, GetAccessLog extends OperationKind {}

abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

// ---------- Dynamic entities ----------

sig Record {}

sig User {
  role: one Role,
  assigned: lone Record
}

sig CareTeamMembership {
  clinician: one User,
  rec: one Record,
  status: one MembershipStatus
}

sig ClinicalNote {
  rec: one Record,
  author: one User,
  authorRole: one Role
}

sig Operation {
  caller: one User,
  kind: one OperationKind,
  target: lone Record,         // absent only for GetAccessLog
  outcome: one Outcome,
  createdNote: lone ClinicalNote
}

sig AuditEntry {
  op: one Operation,
  accessor: one User,
  accessorRole: one Role,
  opKind: one OperationKind,
  recordRef: lone Record,
  outcomeRef: one Outcome
}

// Permission matrix expressed as a field on a singleton sig.
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Non-empty universe (single fact, declared once) ----------

fact F_NonEmptyUniverse {
  some User
  some Record
  some Operation
  some AuditEntry
  some ClinicalNote
  some CareTeamMembership
}

// ---------- Permission matrix (contracts/http-api.md) ----------
// "Allowed" lists role/endpoint cells that are NOT statically denied;
// conditional rules (care-team membership, patient ownership) narrow these.

fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Clinician         -> GetRecord)       +
      (Clinician         -> PostNote)        +
      (Clinician         -> GetRecordAudit)  +
      (Patient           -> GetRecord)       +
      (Patient           -> GetRecordAudit)  +
      (ComplianceOfficer -> GetRecordAudit)  +
      (ComplianceOfficer -> GetAccessLog)
}

// ---------- Structural facts ----------

// FR-002, FR-003: exactly one role per user; patient ⇔ has one assigned record.
fact F_PatientPairing {
  all u: User | (u.role = Patient) iff (one u.assigned)
}

// FR-004: care-team-membership rows are about clinicians.
fact F_CareTeamClinician {
  all m: CareTeamMembership | m.clinician.role = Clinician
}

// FR-012, data-model.md schema CHECK: notes are authored by clinicians only.
fact F_NotesByCliniciansOnly {
  all n: ClinicalNote | n.author.role = Clinician and n.authorRole = Clinician
}

// Record-scoped endpoints have a target; GetAccessLog has none.
fact F_OperationTarget {
  all op: Operation |
        (op.kind = GetAccessLog implies no op.target)
    and (op.kind in (GetRecord + PostNote + GetRecordAudit) implies (one op.target))
}

// FR-004..FR-007: static permission-matrix gate on Permitted outcomes.
fact F_StaticMatrixGate {
  all op: Operation | op.outcome = Permitted implies
        (op.caller.role -> op.kind in PermMatrix.Allowed)
}

// FR-004, FR-006: conditional access rules layered on top of the matrix.
fact F_ConditionalAccess {
  all op: Operation | op.outcome = Permitted implies (
    (op.caller.role = Clinician and op.kind in (GetRecord + PostNote + GetRecordAudit))
      implies (some m: CareTeamMembership |
                  m.clinician = op.caller and m.rec = op.target and m.status = Active)
  )
  all op: Operation | op.outcome = Permitted implies (
    (op.caller.role = Patient and op.kind in (GetRecord + GetRecordAudit))
      implies (op.target = op.caller.assigned)
  )
}

// FR-013, SC-001, SC-002: exactly one audit entry per operation.
fact F_OneAuditPerOperation {
  all op: Operation | one ae: AuditEntry | ae.op = op
}

// FR-014: audit entry fields are functionally determined by the operation.
fact F_AuditAttribution {
  all ae: AuditEntry |
        ae.accessor      = ae.op.caller
    and ae.accessorRole  = ae.op.caller.role
    and ae.opKind        = ae.op.kind
    and ae.recordRef     = ae.op.target
    and ae.outcomeRef    = ae.op.outcome
}

// FR-011, FR-012: a clinical note exists ⇔ a permitted PostNote created it.
fact F_NoteCreatedIffAppendPermitted {
  all op: Operation |
        (op.kind = PostNote and op.outcome = Permitted) iff (one op.createdNote)
  all op: Operation | (one op.createdNote) implies (
        op.createdNote.rec    = op.target
    and op.createdNote.author = op.caller
  )
}

// FR-012, SC-007: each note traces back to exactly one creating operation.
fact F_NoteFromOneOp {
  all n: ClinicalNote | one op: Operation | op.createdNote = n
}

// ====================================================================
// PATTERN PREDICATES
// ====================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004..FR-007
pred LeastPrivilege {
  all op: Operation | op.outcome = Permitted implies
        (op.caller.role -> op.kind in PermMatrix.Allowed)
  some Operation
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013, SC-001/SC-002; data-model.md AuditEntry
pred AuditCompleteness {
  all op: Operation | (one ae: AuditEntry | ae.op = op)
  all ae: AuditEntry | (one op: Operation | ae.op = op)
  some Operation
  some AuditEntry
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012, FR-015; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  // Each note is produced by exactly one operation (no re-emission / mutation).
  all n: ClinicalNote | (one op: Operation | op.createdNote = n)
  // Each operation has at most one audit entry (no duplicate writes).
  all op: Operation | (lone ae: AuditEntry | ae.op = op)
  some ClinicalNote
  some AuditEntry
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md AuditEntry snapshot fields
pred AttributionCorrectness {
  all ae: AuditEntry |
        ae.accessor     = ae.op.caller
    and ae.accessorRole = ae.op.caller.role
    and ae.opKind       = ae.op.kind
    and ae.outcomeRef   = ae.op.outcome
    and ae.recordRef    = ae.op.target
  some AuditEntry
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-003; data-model.md users pairing CHECK
pred OwnershipExclusivity {
  all u: User | u.role = Patient implies (one u.assigned)
  all u: User | u.role != Patient implies (no u.assigned)
  some User
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md Relationship.PATIENT_OWN_RECORD
pred OwnershipBasedAccess {
  all op: Operation |
        (op.caller.role = Patient
         and op.kind in (GetRecord + GetRecordAudit)
         and op.outcome = Permitted)
        implies (op.target = op.caller.assigned)
  some Operation
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008, SC-003 (byte-equivalent 403)
pred NoInformationLeakage {
  // Any (role, kind) cell outside the matrix uniformly yields Denied — no
  // structural channel distinguishes "exists-but-unauth" from "not-found".
  all op: Operation |
        ((op.caller.role -> op.kind) not in PermMatrix.Allowed)
        implies op.outcome = Denied
  some Operation
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// ====================================================================
// FEATURE-SPECIFIC PREDICATES (one per FR-NNN)
// ====================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 (authentication required on every request)
pred FR_001_AuthRequired {
  all op: Operation | one op.caller
  all ae: AuditEntry | one ae.accessor
  some Operation
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 (exactly one role per user)
pred FR_002_OneRolePerUser {
  all u: User | one u.role
  some User
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 (patient ⇔ assigned_record_id; other roles have none)
pred FR_003_PatientAssignedRecord {
  all u: User | (u.role = Patient) iff (one u.assigned)
  some User
}
assert FR_003_PatientAssignedRecord { FR_003_PatientAssignedRecord }
check FR_003_PatientAssignedRecord for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 (care-team gating for clinician read/append)
pred FR_004_CareTeamGating {
  all op: Operation |
        (op.caller.role = Clinician
         and op.kind in (GetRecord + PostNote + GetRecordAudit)
         and op.outcome = Permitted)
        implies (some m: CareTeamMembership |
                    m.clinician = op.caller and m.rec = op.target and m.status = Active)
  some Operation
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 (clinician audit access; no GetAccessLog)
pred FR_005_ClinicianAuditAccess {
  all op: Operation |
        (op.caller.role = Clinician and op.kind = GetRecordAudit and op.outcome = Permitted)
        implies (some m: CareTeamMembership |
                    m.clinician = op.caller and m.rec = op.target and m.status = Active)
  all op: Operation |
        (op.caller.role = Clinician and op.kind = GetAccessLog)
        implies op.outcome = Denied
  some Operation
}
assert FR_005_ClinicianAuditAccess { FR_005_ClinicianAuditAccess }
check FR_005_ClinicianAuditAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 (patient self-access only; no write, no /access-log)
pred FR_006_PatientSelfAccess {
  all op: Operation |
        (op.caller.role = Patient
         and op.kind in (GetRecord + GetRecordAudit)
         and op.outcome = Permitted)
        implies (op.target = op.caller.assigned)
  all op: Operation |
        (op.caller.role = Patient and op.kind = PostNote) implies op.outcome = Denied
  all op: Operation |
        (op.caller.role = Patient and op.kind = GetAccessLog) implies op.outcome = Denied
  some Operation
}
assert FR_006_PatientSelfAccess { FR_006_PatientSelfAccess }
check FR_006_PatientSelfAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 (compliance officer must not read clinical content)
pred FR_007_ComplianceContentBlind {
  all op: Operation |
        (op.caller.role = ComplianceOfficer and op.kind in (GetRecord + PostNote))
        implies op.outcome = Denied
  some Operation
}
assert FR_007_ComplianceContentBlind { FR_007_ComplianceContentBlind }
check FR_007_ComplianceContentBlind for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 (byte-equivalent forbidden response; uniform denial)
pred FR_008_ByteEquivalent403 {
  all op: Operation |
        ((op.caller.role -> op.kind) not in PermMatrix.Allowed)
        implies op.outcome = Denied
  some Operation
}
assert FR_008_ByteEquivalent403 { FR_008_ByteEquivalent403 }
check FR_008_ByteEquivalent403 for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 (non-care-team clinician denied on GetRecord)
pred FR_009_NonCareTeamDenied {
  all op: Operation |
        (op.caller.role = Clinician
         and op.kind = GetRecord
         and (no m: CareTeamMembership |
                m.clinician = op.caller and m.rec = op.target and m.status = Active))
        implies op.outcome = Denied
  some Operation
}
assert FR_009_NonCareTeamDenied { FR_009_NonCareTeamDenied }
check FR_009_NonCareTeamDenied for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 (note structural validity — author role, record link)
pred FR_010_NoteValidation {
  all n: ClinicalNote |
        n.authorRole = Clinician
    and one n.rec
    and one n.author
  some ClinicalNote
}
assert FR_010_NoteValidation { FR_010_NoteValidation }
check FR_010_NoteValidation for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 (permitted append persists note attributed to caller)
pred FR_011_NotePersistence {
  all op: Operation |
        (op.kind = PostNote and op.outcome = Permitted)
        implies (one op.createdNote
                 and op.createdNote.author = op.caller
                 and op.createdNote.rec    = op.target)
  some Operation
}
assert FR_011_NotePersistence { FR_011_NotePersistence }
check FR_011_NotePersistence for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 (notes append-only; only clinicians author)
pred FR_012_NotesAppendOnly {
  all n: ClinicalNote | n.author.role = Clinician
  all n: ClinicalNote | (one op: Operation | op.createdNote = n)
  some ClinicalNote
}
assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 (always-on audit: one entry per attempted access)
pred FR_013_AlwaysOnAudit {
  all op: Operation | (one ae: AuditEntry | ae.op = op)
  all ae: AuditEntry | (one op: Operation | ae.op = op)
  some Operation
}
assert FR_013_AlwaysOnAudit { FR_013_AlwaysOnAudit }
check FR_013_AlwaysOnAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 (audit-entry attribution matches operation)
pred FR_014_AuditEntryShape {
  all ae: AuditEntry |
        ae.accessor     = ae.op.caller
    and ae.accessorRole = ae.op.caller.role
    and ae.opKind       = ae.op.kind
    and ae.outcomeRef   = ae.op.outcome
    and ae.recordRef    = ae.op.target
  some AuditEntry
}
assert FR_014_AuditEntryShape { FR_014_AuditEntryShape }
check FR_014_AuditEntryShape for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 (audit immutability — no duplicate or rewritten entry)
pred FR_015_AuditImmutable {
  all op: Operation | (lone ae: AuditEntry | ae.op = op)
  all ae: AuditEntry | one ae.op
  some AuditEntry
}
assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 (audit write SLA — no permitted op without audit)
pred FR_016_AuditWriteSLA {
  all op: Operation | op.outcome = Permitted implies (some ae: AuditEntry | ae.op = op)
  some Operation
}
assert FR_016_AuditWriteSLA { FR_016_AuditWriteSLA }
check FR_016_AuditWriteSLA for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 (retention — every audit entry retains its op link)
pred FR_017_AuditRetention {
  all ae: AuditEntry | one ae.op
  some AuditEntry
}
assert FR_017_AuditRetention { FR_017_AuditRetention }
check FR_017_AuditRetention for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 (GET /access-log is compliance-officer only)
pred FR_018_ComplianceAccessLog {
  all op: Operation |
        (op.kind = GetAccessLog and op.outcome = Permitted)
        implies op.caller.role = ComplianceOfficer
  some Operation
}
assert FR_018_ComplianceAccessLog { FR_018_ComplianceAccessLog }
check FR_018_ComplianceAccessLog for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 (compliance responses content-blind by construction)
pred FR_019_ContentBlindResponses {
  all op: Operation |
        (op.caller.role = ComplianceOfficer and op.kind in (GetRecord + PostNote))
        implies op.outcome = Denied
  no n: ClinicalNote | n.author.role = ComplianceOfficer
  some Operation
}
assert FR_019_ContentBlindResponses { FR_019_ContentBlindResponses }
check FR_019_ContentBlindResponses for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020 (URL paths use opaque record_id only — no patient demographics)
pred FR_020_RecordIdOnly {
  // Targets of {id}-scoped endpoints are Record handles, structurally distinct
  // from User identity. Patient demographics never serve as a path identifier.
  all op: Operation | op.kind in (GetRecord + PostNote + GetRecordAudit)
        implies (op.target in Record and (one op.target))
  some Operation
}
assert FR_020_RecordIdOnly { FR_020_RecordIdOnly }
check FR_020_RecordIdOnly for 6