// === feature_model.als — Alloy model for 013-hipaa-clinical-records ===
//
// Encodes the HIPAA clinical record access feature: roles
// {clinician, patient, compliance_officer} × endpoints
// {GET /records/{id}, POST /records/{id}/notes, GET /records/{id}/audit,
//  GET /access-log}, with care-team gating, patient own-record gating,
// compliance content-blindness, byte-equivalent 403 envelope, always-on
// append-only immutable audit log.

// ---- Roles, endpoints, operation kinds, outcomes ----

abstract sig Role {}
one sig ClinicianRole, PatientRole, ComplianceOfficerRole extends Role {}

abstract sig OperationKind {}
one sig Read, Append, List extends OperationKind {}

abstract sig Endpoint {}
one sig GetRecord, PostNote, GetRecordAudit, GetAccessLog extends Endpoint {}

abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

abstract sig Response {}
one sig ForbiddenEnvelope, OkRecordResponse, CreatedNoteResponse,
        PerRecordAuditResponse, AccessLogResponse extends Response {}

// Authenticated marker: op.authenticated non-empty iff the request reached
// the handler with a resolved identity. FR-001 says unauth requests are
// rejected at the boundary; we model that as no authenticated marker.
one sig AuthFlag {}

// ---- Domain entities ----

sig Record {}

sig User {
  role: one Role,
  assignedRecord: lone Record         // populated iff role = PatientRole
}

sig CareTeamMembership {
  clinician: one User,
  record: one Record
}

sig ClinicalNote {
  noteRecord: one Record,
  author: one User,
  authorRoleSnapshot: one Role
}

sig Operation {
  caller: one User,
  callerRoleSnapshot: one Role,
  endpoint: one Endpoint,
  kind: one OperationKind,
  targetRecord: lone Record,           // none for GetAccessLog
  authenticated: lone AuthFlag,        // present iff authenticated
  outcome: one Outcome,
  response: one Response,
  createdNote: lone ClinicalNote
}

sig AuditEntry {
  forOp: one Operation,
  recordedRole: one Role,
  recordedUser: one User,
  recordedRecord: lone Record,
  recordedOp: one OperationKind,
  recordedOutcome: one Outcome,
  recordedNote: lone ClinicalNote
}

// ---- Permission matrix (singleton-sig field) ----
//
// "Allow" cells (some path can succeed) per contracts/http-api.md.
// Conditions (care-team membership / own record) are layered on top
// via separate facts; this matrix is the role-level gate.
one sig PermMatrix { Allowed: set Role -> Endpoint }

// =====================================================================
// Non-empty universe — declared ONCE here, never inlined in predicates.
// =====================================================================
fact F_NonEmptyUniverse {
  some User
  some Record
  some Operation
  some AuditEntry
  some CareTeamMembership
  some ClinicalNote
}

// =====================================================================
// Structural facts (named so the validator can mutate them)
// =====================================================================

fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (ClinicianRole          -> GetRecord)
    + (ClinicianRole          -> PostNote)
    + (ClinicianRole          -> GetRecordAudit)
    + (PatientRole            -> GetRecord)
    + (PatientRole            -> GetRecordAudit)
    + (ComplianceOfficerRole  -> GetRecordAudit)
    + (ComplianceOfficerRole  -> GetAccessLog)
}

fact F_KindMatchesEndpoint {
  all op: Operation |
        (op.endpoint = GetRecord       implies op.kind = Read)
    and (op.endpoint = PostNote        implies op.kind = Append)
    and (op.endpoint = GetRecordAudit  implies op.kind = List)
    and (op.endpoint = GetAccessLog    implies op.kind = List)
}

fact F_TargetRecordShape {
  // Record-scoped endpoints carry a target; GetAccessLog does not.
  all op: Operation |
        (op.endpoint in (GetRecord + PostNote + GetRecordAudit) implies some op.targetRecord)
    and (op.endpoint = GetAccessLog implies no op.targetRecord)
}

fact F_CallerRoleSnapshot {
  all op: Operation | op.callerRoleSnapshot = op.caller.role
}

// FR-003: patient role <=> assignedRecord present
fact F_PatientAssignedRecord {
  all u: User | u.role = PatientRole iff some u.assignedRecord
}

// FR-011: clinical notes can only be authored by clinicians
fact F_NoteAuthorIsClinician {
  all n: ClinicalNote | n.author.role = ClinicianRole
  all n: ClinicalNote | n.authorRoleSnapshot = ClinicianRole
}

// FR-001: unauthenticated => no audit entry written, outcome forced denied
fact F_UnauthenticatedNoAudit {
  all op: Operation | no op.authenticated implies op.outcome = Denied
  all op: Operation | no op.authenticated implies (no ae: AuditEntry | ae.forOp = op)
}

// FR-013, FR-016: every authenticated access produces exactly one audit entry
fact F_AuditCompleteness {
  all op: Operation | some op.authenticated implies (one ae: AuditEntry | ae.forOp = op)
}

// FR-015: audit entries are unique per operation (proxy for immutability +
// no duplicates).  Combined with F_AuditCompleteness this makes the
// op<->audit relation a one-to-one injection.
fact F_AuditUniquePerOp { /* MUTATED — body cleared by validator */ }

// FR-014: audit entry mirrors operation attributes (attribution correctness)
fact F_AuditAttribution {
  all ae: AuditEntry |
        ae.recordedUser    = ae.forOp.caller
    and ae.recordedRole    = ae.forOp.callerRoleSnapshot
    and ae.recordedRecord  = ae.forOp.targetRecord
    and ae.recordedOp      = ae.forOp.kind
    and ae.recordedOutcome = ae.forOp.outcome
    and ae.recordedNote    = ae.forOp.createdNote
}

// FR-004 / FR-005 / FR-006 / FR-007 / FR-018: split into per-role facts so
// each can be mutation-tested independently.

fact F_LeastPrivilegeMatrix {
  all op: Operation |
    (some op.authenticated and op.outcome = Permitted)
      implies op.caller.role -> op.endpoint in PermMatrix.Allowed
}

fact F_ClinicianCareTeamGating {
  all op: Operation |
    (some op.authenticated and op.outcome = Permitted
      and op.caller.role = ClinicianRole
      and op.endpoint in (GetRecord + PostNote + GetRecordAudit))
    implies (some m: CareTeamMembership |
               m.clinician = op.caller and m.record = op.targetRecord)
}

fact F_PatientOwnRecordGating {
  all op: Operation |
    (some op.authenticated and op.outcome = Permitted
      and op.caller.role = PatientRole)
    implies (op.endpoint in (GetRecord + GetRecordAudit)
             and op.targetRecord = op.caller.assignedRecord)
}

fact F_ComplianceNoClinicalRead {
  all op: Operation |
    (some op.authenticated and op.outcome = Permitted
      and op.caller.role = ComplianceOfficerRole)
    implies op.endpoint in (GetRecordAudit + GetAccessLog)
}

// FR-008: every authenticated denial returns the canonical forbidden envelope
fact F_ByteEquivalentForbidden {
  all op: Operation |
    (some op.authenticated and op.outcome = Denied)
      implies op.response = ForbiddenEnvelope
}

// Shape of permitted responses (distinct from ForbiddenEnvelope)
fact F_PermittedResponseShapes {
  all op: Operation | (op.outcome = Permitted and op.endpoint = GetRecord)       implies op.response = OkRecordResponse
  all op: Operation | (op.outcome = Permitted and op.endpoint = PostNote)        implies op.response = CreatedNoteResponse
  all op: Operation | (op.outcome = Permitted and op.endpoint = GetRecordAudit)  implies op.response = PerRecordAuditResponse
  all op: Operation | (op.outcome = Permitted and op.endpoint = GetAccessLog)    implies op.response = AccessLogResponse
}

// FR-011/FR-012: notes have exactly one creating Append operation; no
// "mutate note" code path exists in the model (no operation that touches
// an existing note).
fact F_AppendOnlyNotes {
  all n: ClinicalNote | one op: Operation | op.createdNote = n
  all op: Operation | some op.createdNote implies op.kind = Append
  all op: Operation | some op.createdNote implies op.outcome = Permitted
  all op: Operation | some op.createdNote implies some op.authenticated
}

// Note creation linkage to caller / record
fact F_NoteCreationLinkage {
  all op: Operation | some op.createdNote implies {
    op.createdNote.noteRecord = op.targetRecord
    op.createdNote.author     = op.caller
  }
}

// =====================================================================
// PATTERN PREDICATES + ASSERTIONS
// =====================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004..FR-007, FR-018
pred LeastPrivilege {
  all op: Operation |
    op.outcome = Permitted
      implies op.caller.role -> op.endpoint in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md matrix has 12 cells, 7 allowed
pred PermissionCompleteness {
  #PermMatrix.Allowed = 7
  // Each role has at least one allowed endpoint and the access-log endpoint
  // has exactly one allowed role.
  all r: Role | some e: Endpoint | r -> e in PermMatrix.Allowed
  one r: Role | r -> GetAccessLog in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, SC-009
pred AuthRequiredEverywhere {
  all op: Operation | no op.authenticated implies op.outcome = Denied
  all op: Operation | no op.authenticated implies (no ae: AuditEntry | ae.forOp = op)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013, SC-001, SC-002
pred AuditCompleteness {
  all op: Operation | some op.authenticated implies (one ae: AuditEntry | ae.forOp = op)
  all ae: AuditEntry | some ae.forOp.authenticated
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012 (notes), FR-015 (audit), SC-007, SC-008
pred AppendOnly {
  // Audit immutability proxy: at most one AuditEntry per Operation.
  all disj ae1, ae2: AuditEntry | ae1.forOp != ae2.forOp
  // Notes are created by exactly one Append op and never re-authored.
  all n: ClinicalNote | one op: Operation | op.createdNote = n
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md audit fields
pred AttributionCorrectness {
  all ae: AuditEntry |
        ae.recordedUser    = ae.forOp.caller
    and ae.recordedRole    = ae.forOp.callerRoleSnapshot
    and ae.recordedOp      = ae.forOp.kind
    and ae.recordedOutcome = ae.forOp.outcome
    and ae.recordedRecord  = ae.forOp.targetRecord
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md User.assigned_record_id pairing CHECK; spec.md FR-003
pred OwnershipExclusivity {
  all u: User | u.role = PatientRole iff some u.assignedRecord
  all u: User | lone u.assignedRecord
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md Relationship.PATIENT_OWN_RECORD
pred OwnershipBasedAccess {
  all op: Operation |
    (some op.authenticated and op.outcome = Permitted
      and op.caller.role = PatientRole)
    implies op.targetRecord = op.caller.assignedRecord
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008, SC-003; contracts/http-api.md forbidden envelope
pred NoInformationLeakage {
  // Every authenticated denial returns the same canonical envelope —
  // cannot distinguish "record exists but you can't see it" from
  // "record does not exist."
  all op: Operation |
    (some op.authenticated and op.outcome = Denied)
      implies op.response = ForbiddenEnvelope
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-010, FR-016 (rollback on audit failure)
pred ValidationBeforeMutation {
  // No ClinicalNote exists unless it was produced by an authenticated,
  // permitted Append operation whose audit entry also exists.
  all n: ClinicalNote | some op: Operation |
        op.createdNote = n
    and some op.authenticated
    and op.outcome = Permitted
    and op.kind = Append
    and (one ae: AuditEntry | ae.forOp = op)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// =====================================================================
// FEATURE-SPECIFIC FR ASSERTIONS — one per FR-NNN
// =====================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all op: Operation | no op.authenticated implies op.outcome = Denied
  all op: Operation | no op.authenticated implies (no ae: AuditEntry | ae.forOp = op)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 (exactly one role per user)
pred FR_002_OneRolePerUser {
  all u: User | one u.role
  all u: User | u.role in (ClinicianRole + PatientRole + ComplianceOfficerRole)
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_PatientAssignedRecord {
  all u: User | u.role = PatientRole iff some u.assignedRecord
}
assert FR_003_PatientAssignedRecord { FR_003_PatientAssignedRecord }
check FR_003_PatientAssignedRecord for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_CareTeamGating {
  all op: Operation |
    (some op.authenticated and op.outcome = Permitted
      and op.caller.role = ClinicianRole
      and op.endpoint in (GetRecord + PostNote + GetRecordAudit))
    implies (some m: CareTeamMembership |
               m.clinician = op.caller and m.record = op.targetRecord)
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 (clinician cannot use GET /access-log)
pred FR_005_ClinicianNoAccessLog {
  all op: Operation |
    (some op.authenticated and op.caller.role = ClinicianRole
      and op.endpoint = GetAccessLog)
    implies op.outcome = Denied
}
assert FR_005_ClinicianNoAccessLog { FR_005_ClinicianNoAccessLog }
check FR_005_ClinicianNoAccessLog for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_PatientOwnRecordOnly {
  all op: Operation |
    (some op.authenticated and op.outcome = Permitted
      and op.caller.role = PatientRole)
    implies (op.endpoint in (GetRecord + GetRecordAudit)
             and op.targetRecord = op.caller.assignedRecord)
}
assert FR_006_PatientOwnRecordOnly { FR_006_PatientOwnRecordOnly }
check FR_006_PatientOwnRecordOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 (compliance officer cannot read clinical content)
pred FR_007_ComplianceNoClinicalRead {
  all op: Operation |
    (some op.authenticated and op.outcome = Permitted
      and op.caller.role = ComplianceOfficerRole)
    implies op.endpoint in (GetRecordAudit + GetAccessLog)
}
assert FR_007_ComplianceNoClinicalRead { FR_007_ComplianceNoClinicalRead }
check FR_007_ComplianceNoClinicalRead for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_ByteEquivalentForbidden {
  all op: Operation |
    (some op.authenticated and op.outcome = Denied)
      implies op.response = ForbiddenEnvelope
}
assert FR_008_ByteEquivalentForbidden { FR_008_ByteEquivalentForbidden }
check FR_008_ByteEquivalentForbidden for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 (clinician not in care team reading record => 403 envelope)
pred FR_009_NonCareTeamClinicianForbidden {
  all op: Operation |
    (some op.authenticated and op.caller.role = ClinicianRole
      and op.endpoint = GetRecord
      and (no m: CareTeamMembership |
             m.clinician = op.caller and m.record = op.targetRecord))
    implies (op.outcome = Denied and op.response = ForbiddenEnvelope)
}
assert FR_009_NonCareTeamClinicianForbidden { FR_009_NonCareTeamClinicianForbidden }
check FR_009_NonCareTeamClinicianForbidden for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 (validation precedes mutation — no note without permitted append)
pred FR_010_ValidationGatesNote {
  all n: ClinicalNote | some op: Operation |
        op.createdNote = n
    and op.outcome = Permitted
    and op.kind = Append
}
assert FR_010_ValidationGatesNote { FR_010_ValidationGatesNote }
check FR_010_ValidationGatesNote for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 (author identity / role snapshot)
pred FR_011_AuthorSnapshot {
  all n: ClinicalNote | n.authorRoleSnapshot = ClinicianRole
  all n: ClinicalNote | n.author.role = ClinicianRole
}
assert FR_011_AuthorSnapshot { FR_011_AuthorSnapshot }
check FR_011_AuthorSnapshot for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 (notes append-only)
pred FR_012_NotesAppendOnly {
  all n: ClinicalNote | one op: Operation | op.createdNote = n
  all op: Operation | some op.createdNote implies op.kind = Append
}
assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_AuditPerAccess {
  all op: Operation | some op.authenticated implies (one ae: AuditEntry | ae.forOp = op)
  all ae: AuditEntry | some ae.forOp.authenticated
}
assert FR_013_AuditPerAccess { FR_013_AuditPerAccess }
check FR_013_AuditPerAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_AuditFields {
  all ae: AuditEntry |
        ae.recordedUser    = ae.forOp.caller
    and ae.recordedRole    = ae.forOp.callerRoleSnapshot
    and ae.recordedRecord  = ae.forOp.targetRecord
    and ae.recordedOp      = ae.forOp.kind
    and ae.recordedOutcome = ae.forOp.outcome
    and ae.recordedNote    = ae.forOp.createdNote
}
assert FR_014_AuditFields { FR_014_AuditFields }
check FR_014_AuditFields for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 (audit immutability)
pred FR_015_AuditImmutable {
  all disj ae1, ae2: AuditEntry | ae1.forOp != ae2.forOp
}
assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 (audit-write synchronous — every permitted op carries its audit)
pred FR_016_AuditSynchronous {
  all op: Operation |
    (some op.authenticated and op.outcome = Permitted)
      implies (one ae: AuditEntry | ae.forOp = op)
}
assert FR_016_AuditSynchronous { FR_016_AuditSynchronous }
check FR_016_AuditSynchronous for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 (no deletion path — every authenticated op
// retains its audit entry)
pred FR_017_AuditRetention {
  all op: Operation |
    some op.authenticated implies (some ae: AuditEntry | ae.forOp = op)
}
assert FR_017_AuditRetention { FR_017_AuditRetention }
check FR_017_AuditRetention for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 (access-log compliance-officer-only)
pred FR_018_AccessLogComplianceOnly {
  all op: Operation |
    (some op.authenticated and op.endpoint = GetAccessLog
      and op.outcome = Permitted)
    implies op.caller.role = ComplianceOfficerRole
}
assert FR_018_AccessLogComplianceOnly { FR_018_AccessLogComplianceOnly }
check FR_018_AccessLogComplianceOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 (compliance responses content-blind —
// no permitted GetRecord/PostNote for a compliance officer)
pred FR_019_ComplianceContentBlind {
  all op: Operation |
    (some op.authenticated and op.caller.role = ComplianceOfficerRole
      and op.endpoint in (GetRecord + PostNote))
    implies op.outcome = Denied
}
assert FR_019_ComplianceContentBlind { FR_019_ComplianceContentBlind }
check FR_019_ComplianceContentBlind for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020 (URL paths use opaque record_id —
// every record-scoped op references a Record, never a User demographic)
pred FR_020_RecordIdOnlyInUrl {
  all op: Operation |
    op.endpoint in (GetRecord + PostNote + GetRecordAudit)
      implies some op.targetRecord
  all op: Operation |
    op.endpoint = GetAccessLog implies no op.targetRecord
}
assert FR_020_RecordIdOnlyInUrl { FR_020_RecordIdOnlyInUrl }
check FR_020_RecordIdOnlyInUrl for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_DuplicateAudit { some disj ae1, ae2: AuditEntry | ae1.forOp = ae2.forOp }
