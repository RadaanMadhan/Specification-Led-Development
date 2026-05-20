// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===
// Feature: C-L3 (013-hipaa-clinical-records)
//
// This model encodes the structural invariants of the HIPAA clinical-record-
// access feature: role-based access (clinician/patient/compliance_officer),
// care-team-membership gating, patient self-access, byte-equivalent 403
// envelope, append-only clinical notes and audit entries, and compliance
// content-blindness on audit endpoints.

// ----------------------------------------------------------------------
// Catalogue enums (fixed atom count)
// ----------------------------------------------------------------------

abstract sig Role {}
one sig Clinician extends Role {}
one sig Patient extends Role {}
one sig ComplianceOfficer extends Role {}

abstract sig OperationKind {}
one sig EpGetRecord extends OperationKind {}
one sig EpPostNote extends OperationKind {}
one sig EpGetRecordAudit extends OperationKind {}
one sig EpGetAccessLog extends OperationKind {}

abstract sig OpType {}
one sig ReadOp extends OpType {}
one sig AppendOp extends OpType {}
one sig ListOp extends OpType {}

abstract sig Outcome {}
one sig Permitted extends Outcome {}
one sig Denied extends Outcome {}

abstract sig RespBytes {}
one sig CanonicalForbidden extends RespBytes {}
one sig ClinicalContent extends RespBytes {}
one sig AuditMetadataOnly extends RespBytes {}

// ----------------------------------------------------------------------
// Dynamic entities (from data-model.md)
// ----------------------------------------------------------------------

sig IPAddress {}

sig Record {}

sig User {
  role: one Role,
  assignedRecord: lone Record
}

sig CareTeamMembership {
  ctClinician: one User,
  ctRecord: one Record
}

sig ClinicalNote {
  noteRecord: one Record,
  noteAuthor: one User,
  noteAuthorRole: one Role
}

sig Operation {
  caller: lone User,            // lone => unauthenticated request is `no caller`
  endpoint: one OperationKind,
  targetRec: lone Record,
  opType: one OpType,
  outcome: one Outcome,
  response: one RespBytes,
  callerIP: one IPAddress
}

sig AuditEntry {
  auditOp: one Operation,
  auditAccessor: one User,
  auditRole: one Role,
  auditRec: lone Record,
  auditOpType: one OpType,
  auditOutcome: one Outcome,
  auditNote: lone ClinicalNote,
  auditIP: one IPAddress
}

// Permission matrix singleton (Role x OperationKind cells from contracts/http-api.md).
one sig PermMatrix {
  Permissible: set Role -> OperationKind,
  Unconditional: set Role -> OperationKind
}

// ----------------------------------------------------------------------
// Non-empty universe (single named fact; no inline witnesses in preds)
// ----------------------------------------------------------------------

fact F_NonEmptyUniverse {
  some User
  some Record
  some CareTeamMembership
  some ClinicalNote
  some Operation
  some AuditEntry
  some IPAddress
}

// ----------------------------------------------------------------------
// Permission matrix (closed-world enumeration of contracts/http-api.md)
// ----------------------------------------------------------------------

fact F_PermissionMatrix {
  PermMatrix.Permissible =
    (Clinician -> EpGetRecord) +
    (Patient -> EpGetRecord) +
    (Clinician -> EpPostNote) +
    (Clinician -> EpGetRecordAudit) +
    (Patient -> EpGetRecordAudit) +
    (ComplianceOfficer -> EpGetRecordAudit) +
    (ComplianceOfficer -> EpGetAccessLog)
  PermMatrix.Unconditional =
    (ComplianceOfficer -> EpGetRecordAudit) +
    (ComplianceOfficer -> EpGetAccessLog)
}

// ----------------------------------------------------------------------
// Structural data invariants
// ----------------------------------------------------------------------

fact F_PatientAssignedRecord {
  // FR-003: patient ↔ has assignedRecord; other roles MUST NOT have one
  all u: User | (u.role = Patient) iff (some u.assignedRecord)
}

fact F_NoteAuthorIsClinician {
  // FR-011 / data-model: clinical_notes.author_role CHECK = 'clinician'
  all n: ClinicalNote | n.noteAuthorRole = Clinician
  all n: ClinicalNote | n.noteAuthor.role = Clinician
}

fact F_CareTeamMemberIsClinician {
  // data-model: care_team_memberships.clinician_id is a clinician user
  all m: CareTeamMembership | m.ctClinician.role = Clinician
}

fact F_EndpointOpTypeMapping {
  // contracts: endpoint → recorded operation type
  all op: Operation | op.endpoint = EpGetRecord implies op.opType = ReadOp
  all op: Operation | op.endpoint = EpPostNote implies op.opType = AppendOp
  all op: Operation | op.endpoint = EpGetRecordAudit implies op.opType = ListOp
  all op: Operation | op.endpoint = EpGetAccessLog implies op.opType = ListOp
}

fact F_TargetRecordByEndpoint {
  // FR-020: only record-scoped endpoints carry a targetRec; access-log has none
  all op: Operation | op.endpoint = EpGetAccessLog implies no op.targetRec
  all op: Operation | op.endpoint in (EpGetRecord + EpPostNote + EpGetRecordAudit)
    implies one op.targetRec
}

// ----------------------------------------------------------------------
// Authentication boundary (FR-001)
// ----------------------------------------------------------------------

fact F_AuthRequiredOrDenied {
  // FR-001: unauthenticated ops are denied at the boundary; no audit written
  all op: Operation | no op.caller implies op.outcome = Denied
  all op: Operation | no op.caller implies (no ae: AuditEntry | ae.auditOp = op)
}

// ----------------------------------------------------------------------
// Audit completeness, attribution, linkage (FR-013, FR-014, FR-016)
// ----------------------------------------------------------------------

fact F_AuditOnePerAuthenticatedOp { /* MUTATED — body cleared by validator */ }

fact F_AuditAttribution {
  // FR-011/FR-014: audit entry snapshots its op's caller, role, target, type, outcome, IP
  all ae: AuditEntry | ae.auditAccessor = ae.auditOp.caller
  all ae: AuditEntry | ae.auditRole = ae.auditAccessor.role
  all ae: AuditEntry | ae.auditRec = ae.auditOp.targetRec
  all ae: AuditEntry | ae.auditOpType = ae.auditOp.opType
  all ae: AuditEntry | ae.auditOutcome = ae.auditOp.outcome
  all ae: AuditEntry | ae.auditIP = ae.auditOp.callerIP
}

fact F_AuditNoteLinkage {
  // FR-014: note_id present iff (operation=append AND outcome=permitted)
  all ae: AuditEntry | some ae.auditNote iff
    (ae.auditOpType = AppendOp and ae.auditOutcome = Permitted)
  all ae: AuditEntry | some ae.auditNote implies ae.auditNote.noteRecord = ae.auditRec
}

// ----------------------------------------------------------------------
// Authorisation enforcement — least-privilege, ownership, care team
// ----------------------------------------------------------------------

fact F_LeastPrivilege_MatrixGate {
  // FR-005/FR-007/FR-018: permitted ⇒ (role,endpoint) is in the permission matrix
  all op: Operation | op.outcome = Permitted implies
    (op.caller.role -> op.endpoint) in PermMatrix.Permissible
}

fact F_LeastPrivilege_ClinicianCT {
  // FR-004: clinician's permitted access to record-scoped endpoints requires CT membership
  all op: Operation |
    (op.outcome = Permitted and op.caller.role = Clinician and
     op.endpoint in (EpGetRecord + EpPostNote + EpGetRecordAudit))
    implies (some m: CareTeamMembership |
              m.ctClinician = op.caller and m.ctRecord = op.targetRec)
}

fact F_LeastPrivilege_PatientSelf {
  // FR-006: patient's permitted access targets only their assigned record
  all op: Operation |
    (op.outcome = Permitted and op.caller.role = Patient)
    implies op.targetRec = op.caller.assignedRecord
}

// ----------------------------------------------------------------------
// Notes append-only via permitted append op (FR-011, FR-012)
// ----------------------------------------------------------------------

fact F_NotesViaPermittedAppendOp {
  // FR-012: every clinical note is justified by a permitted append op
  all n: ClinicalNote | some op: Operation |
    op.opType = AppendOp and op.outcome = Permitted and
    op.caller = n.noteAuthor and op.targetRec = n.noteRecord
}

// ----------------------------------------------------------------------
// Response shape (FR-008 byte-equivalent forbidden; FR-019 content-blind)
// ----------------------------------------------------------------------

fact F_ByteEquivalentForbidden {
  // FR-008: denied ⇒ canonical forbidden envelope; permitted ⇒ not canonical
  all op: Operation | op.outcome = Denied implies op.response = CanonicalForbidden
  all op: Operation | op.outcome = Permitted implies op.response != CanonicalForbidden
}

fact F_ResponseTypeByEndpoint {
  // FR-019: which permitted responses carry clinical content vs audit-only
  all op: Operation |
    (op.outcome = Permitted and op.endpoint = EpGetRecord)
    implies op.response = ClinicalContent
  all op: Operation |
    (op.outcome = Permitted and op.endpoint = EpPostNote)
    implies op.response = ClinicalContent
  all op: Operation |
    (op.outcome = Permitted and op.endpoint = EpGetRecordAudit)
    implies op.response = AuditMetadataOnly
  all op: Operation |
    (op.outcome = Permitted and op.endpoint = EpGetAccessLog)
    implies op.response = AuditMetadataOnly
}

// ----------------------------------------------------------------------
// Catalogue patterns
// ----------------------------------------------------------------------

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004/FR-006/FR-007
pred LeastPrivilege {
  all op: Operation | op.outcome = Permitted implies
    (op.caller.role -> op.endpoint) in PermMatrix.Permissible
  no op: Operation |
    op.outcome = Permitted and some op.caller and
    op.caller.role = ComplianceOfficer and
    op.endpoint in (EpGetRecord + EpPostNote)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  (Clinician -> EpGetRecord) in PermMatrix.Permissible
  (Patient -> EpGetRecord) in PermMatrix.Permissible
  (ComplianceOfficer -> EpGetRecord) not in PermMatrix.Permissible
  (Clinician -> EpPostNote) in PermMatrix.Permissible
  (Patient -> EpPostNote) not in PermMatrix.Permissible
  (ComplianceOfficer -> EpPostNote) not in PermMatrix.Permissible
  (Clinician -> EpGetRecordAudit) in PermMatrix.Permissible
  (Patient -> EpGetRecordAudit) in PermMatrix.Permissible
  (ComplianceOfficer -> EpGetRecordAudit) in PermMatrix.Permissible
  (Clinician -> EpGetAccessLog) not in PermMatrix.Permissible
  (Patient -> EpGetAccessLog) not in PermMatrix.Permissible
  (ComplianceOfficer -> EpGetAccessLog) in PermMatrix.Permissible
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md "Authentication"
pred AuthRequiredEverywhere {
  all op: Operation | no op.caller implies op.outcome = Denied
  all op: Operation | no op.caller implies (no ae: AuditEntry | ae.auditOp = op)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; SC-001/SC-002; data-model.md audit_entries
pred AuditCompleteness {
  all op: Operation | some op.caller implies (one ae: AuditEntry | ae.auditOp = op)
  all ae: AuditEntry | one ae.auditOp
  some AuditEntry
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012/FR-015; data-model.md "no UPDATE/DELETE on clinical_notes or audit_entries"
pred AppendOnly {
  all op: Operation | op.opType in (ReadOp + AppendOp + ListOp)
  all n: ClinicalNote | some op: Operation |
    op.opType = AppendOp and op.outcome = Permitted and
    op.caller = n.noteAuthor and op.targetRec = n.noteRecord
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-011/FR-014; data-model.md audit snapshot fields
pred AttributionCorrectness {
  all ae: AuditEntry |
    ae.auditAccessor = ae.auditOp.caller and
    ae.auditRole = ae.auditAccessor.role and
    ae.auditRec = ae.auditOp.targetRec and
    ae.auditOpType = ae.auditOp.opType and
    ae.auditOutcome = ae.auditOp.outcome
  some AuditEntry
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004/FR-006; data-model.md care_team_memberships
pred OwnershipBasedAccess {
  all op: Operation |
    (op.outcome = Permitted and op.caller.role = Clinician and
     op.endpoint in (EpGetRecord + EpPostNote + EpGetRecordAudit))
    implies (some m: CareTeamMembership |
              m.ctClinician = op.caller and m.ctRecord = op.targetRec)
  all op: Operation |
    (op.outcome = Permitted and op.caller.role = Patient)
    implies op.targetRec = op.caller.assignedRecord
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008/SC-003; contracts/http-api.md "Byte-equivalent forbidden response"
pred NoInformationLeakage {
  all op: Operation | op.outcome = Denied implies op.response = CanonicalForbidden
  all op: Operation | op.outcome = Permitted implies op.response != CanonicalForbidden
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// ----------------------------------------------------------------------
// FR-by-FR predicates
// ----------------------------------------------------------------------

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication required at the boundary
pred FR_001_AuthRequired {
  all op: Operation | no op.caller implies op.outcome = Denied
  all op: Operation | no op.caller implies (no ae: AuditEntry | ae.auditOp = op)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 a user holds exactly one role
pred FR_002_OneRolePerUser {
  all u: User | one u.role
  some User
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 patient has assigned record; other roles do not
pred FR_003_PatientAssignedRecord {
  all u: User | (u.role = Patient) iff (some u.assignedRecord)
  some User
}
assert FR_003_PatientAssignedRecord { FR_003_PatientAssignedRecord }
check FR_003_PatientAssignedRecord for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 clinician access gated by active care-team membership
pred FR_004_ClinicianCareTeamGate {
  all op: Operation |
    (op.outcome = Permitted and op.caller.role = Clinician and
     op.endpoint in (EpGetRecord + EpPostNote))
    implies (some m: CareTeamMembership |
              m.ctClinician = op.caller and m.ctRecord = op.targetRec)
}
assert FR_004_ClinicianCareTeamGate { FR_004_ClinicianCareTeamGate }
check FR_004_ClinicianCareTeamGate for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 clinicians may NOT call /access-log
pred FR_005_ClinicianNoAccessLog {
  no op: Operation |
    op.outcome = Permitted and some op.caller and
    op.caller.role = Clinician and op.endpoint = EpGetAccessLog
}
assert FR_005_ClinicianNoAccessLog { FR_005_ClinicianNoAccessLog }
check FR_005_ClinicianNoAccessLog for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 patient self-access only
pred FR_006_PatientSelfOnly {
  all op: Operation |
    (op.outcome = Permitted and op.caller.role = Patient)
    implies (op.targetRec = op.caller.assignedRecord and
             op.endpoint in (EpGetRecord + EpGetRecordAudit))
}
assert FR_006_PatientSelfOnly { FR_006_PatientSelfOnly }
check FR_006_PatientSelfOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 compliance officer never reads clinical content
pred FR_007_ComplianceNoClinicalRead {
  no op: Operation |
    op.outcome = Permitted and some op.caller and
    op.caller.role = ComplianceOfficer and
    op.endpoint in (EpGetRecord + EpPostNote)
}
assert FR_007_ComplianceNoClinicalRead { FR_007_ComplianceNoClinicalRead }
check FR_007_ComplianceNoClinicalRead for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 byte-equivalent unauthorised response
pred FR_008_ByteEquivalent403 {
  all op: Operation | op.outcome = Denied implies op.response = CanonicalForbidden
}
assert FR_008_ByteEquivalent403 { FR_008_ByteEquivalent403 }
check FR_008_ByteEquivalent403 for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 non-CT clinician GET /records/{id} → canonical 403 (structural shadow of the 200ms latency target)
pred FR_009_NonCTClinicianGetRecordDenied {
  all op: Operation |
    (some op.caller and op.caller.role = Clinician and
     op.endpoint = EpGetRecord and
     (no m: CareTeamMembership |
       m.ctClinician = op.caller and m.ctRecord = op.targetRec))
    implies (op.outcome = Denied and op.response = CanonicalForbidden)
}
assert FR_009_NonCTClinicianGetRecordDenied { FR_009_NonCTClinicianGetRecordDenied }
check FR_009_NonCTClinicianGetRecordDenied for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 validation before mutation: a permitted append exists only when caller is a care-team clinician
pred FR_010_ValidationBeforeMutation {
  all op: Operation |
    (op.outcome = Permitted and op.opType = AppendOp)
    implies (some op.caller and op.caller.role = Clinician and
             (some m: CareTeamMembership |
               m.ctClinician = op.caller and m.ctRecord = op.targetRec))
}
assert FR_010_ValidationBeforeMutation { FR_010_ValidationBeforeMutation }
check FR_010_ValidationBeforeMutation for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 note attribution (author role snapshot)
pred FR_011_NoteAttribution {
  all n: ClinicalNote |
    n.noteAuthorRole = Clinician and n.noteAuthor.role = Clinician
  some ClinicalNote
}
assert FR_011_NoteAttribution { FR_011_NoteAttribution }
check FR_011_NoteAttribution for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 clinical notes are append-only (no mutate/delete op type; every note backed by a permitted append)
pred FR_012_NotesAppendOnly {
  all op: Operation | op.opType in (ReadOp + AppendOp + ListOp)
  all n: ClinicalNote | some op: Operation |
    op.opType = AppendOp and op.outcome = Permitted and
    op.caller = n.noteAuthor and op.targetRec = n.noteRecord
}
assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 always-on audit (one audit entry per authenticated op)
pred FR_013_AuditCompleteness {
  all op: Operation | some op.caller implies (one ae: AuditEntry | ae.auditOp = op)
  all ae: AuditEntry | one ae.auditOp
  some AuditEntry
}
assert FR_013_AuditCompleteness { FR_013_AuditCompleteness }
check FR_013_AuditCompleteness for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 audit-entry field shape (snapshots + note linkage)
pred FR_014_AuditFieldShape {
  all ae: AuditEntry |
    ae.auditAccessor = ae.auditOp.caller and
    ae.auditRole = ae.auditAccessor.role and
    ae.auditOpType = ae.auditOp.opType and
    ae.auditOutcome = ae.auditOp.outcome and
    ae.auditIP = ae.auditOp.callerIP
  all ae: AuditEntry | some ae.auditNote iff
    (ae.auditOpType = AppendOp and ae.auditOutcome = Permitted)
}
assert FR_014_AuditFieldShape { FR_014_AuditFieldShape }
check FR_014_AuditFieldShape for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 audit entries immutable (no mutate/delete op type targets audit)
pred FR_015_AuditImmutable {
  all op: Operation | op.opType in (ReadOp + AppendOp + ListOp)
  some AuditEntry
}
assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 no permitted state change without a matching audit entry
pred FR_016_NoStateChangeWithoutAudit {
  all op: Operation |
    (op.outcome = Permitted and op.opType = AppendOp)
    implies (one ae: AuditEntry |
              ae.auditOp = op and some ae.auditNote)
}
assert FR_016_NoStateChangeWithoutAudit { FR_016_NoStateChangeWithoutAudit }
check FR_016_NoStateChangeWithoutAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 audit retention (no delete op type in the catalogue)
pred FR_017_AuditRetention {
  all op: Operation | op.opType in (ReadOp + AppendOp + ListOp)
  some AuditEntry
}
assert FR_017_AuditRetention { FR_017_AuditRetention }
check FR_017_AuditRetention for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 /access-log is compliance-officer-only
pred FR_018_AccessLogComplianceOnly {
  all op: Operation |
    (op.outcome = Permitted and op.endpoint = EpGetAccessLog)
    implies (some op.caller and op.caller.role = ComplianceOfficer)
}
assert FR_018_AccessLogComplianceOnly { FR_018_AccessLogComplianceOnly }
check FR_018_AccessLogComplianceOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 compliance content-blindness
pred FR_019_ComplianceContentBlind {
  no op: Operation |
    some op.caller and op.caller.role = ComplianceOfficer and
    op.response = ClinicalContent
}
assert FR_019_ComplianceContentBlind { FR_019_ComplianceContentBlind }
check FR_019_ComplianceContentBlind for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020 record_id is the only URL path identifier (no patient demographics)
pred FR_020_RecordIdOnlyInUrlPath {
  all op: Operation |
    op.endpoint in (EpGetRecord + EpPostNote + EpGetRecordAudit)
    implies one op.targetRec
  all op: Operation | op.endpoint = EpGetAccessLog implies no op.targetRec
}
assert FR_020_RecordIdOnlyInUrlPath { FR_020_RecordIdOnlyInUrlPath }
check FR_020_RecordIdOnlyInUrlPath for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_MissingAudit { some op: Operation | some op.caller and (no ae: AuditEntry | ae.auditOp = op) }
