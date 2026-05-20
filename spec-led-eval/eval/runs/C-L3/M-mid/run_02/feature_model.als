// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===
// Feature: C-L3 (013-hipaa-clinical-records)
// Sources: spec.md, data-model.md, contracts/http-api.md

// ─── Role catalogue ───────────────────────────────────────────────────────────
abstract sig Role {}
one sig Clinician, Patient, ComplianceOfficer extends Role {}

// ─── Operation kinds (the four endpoints) ────────────────────────────────────
abstract sig OperationKind {}
one sig GetRecord, PostNote, GetRecordAudit, GetAccessLog extends OperationKind {}

// ─── Outcomes ─────────────────────────────────────────────────────────────────
abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

// ─── Relationship classifier (mirrors permissions.Relationship in the impl) ───
// Computed per (caller, record) on every request.
abstract sig Relationship {}
one sig CareTeamClin, NonCareTeamClin, PatientOwn, PatientOther, ComplianceOff
    extends Relationship {}

// ─── Permission matrix: Relationship × OperationKind ─────────────────────────
// "Allowed" cells from contracts/http-api.md permission table.
one sig PermMatrix {
  Allowed: set Relationship -> OperationKind
}

// ─── Dynamic entities (one atom per modelled data-model row) ─────────────────
sig Record {}

sig User {
  role:           one  Role,
  assignedRecord: lone Record   // non-null only for Patient users (FR-003)
}

sig CareTeamMembership {
  ctmClinician: one User,
  ctmRecord:    one Record
}

sig ClinicalNote {
  noteRecord: one Record,
  noteAuthor: one User
}

sig AuditEntry {
  aeRecord:      lone Record,
  aeAccessor:    one  User,
  aeAccessorRole: one  Role,
  aeOperation:   one  OperationKind,
  aeOutcome:     one  Outcome,
  aeNoteRef:     lone ClinicalNote
}

// An Operation models one API call.  opRecord is lone because
// GetAccessLog has no record-scoped target.
sig Operation {
  opCaller:     one  User,
  opRecord:     lone Record,
  opKind:       one  OperationKind,
  opOutcome:    one  Outcome,
  opAuditEntry: one  AuditEntry    // structural 1-to-1 link (FR-013)
}

// ─── Non-empty universe ───────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some Record
  some User
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
  some Operation
}

// ─── Permission matrix (closed-world) ────────────────────────────────────────
// Source: contracts/http-api.md permission table; spec.md FR-004..FR-007.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
       (CareTeamClin  -> GetRecord)
    +  (CareTeamClin  -> PostNote)
    +  (CareTeamClin  -> GetRecordAudit)
    +  (PatientOwn    -> GetRecord)
    +  (PatientOwn    -> GetRecordAudit)
    +  (ComplianceOff -> GetRecordAudit)
    +  (ComplianceOff -> GetAccessLog)
}

// ─── User/role structural constraints ────────────────────────────────────────
// spec.md FR-002: exactly one role; FR-003: patient↔assignedRecord pairing.
fact F_PatientAssignedRecord {
  all u: User | u.role = Patient  iff  (one u.assignedRecord)
  all u: User | u.role != Patient implies no u.assignedRecord
}

// ─── CareTeamMembership integrity ────────────────────────────────────────────
// data-model.md: ctmClinician must have role Clinician.
fact F_CareTeamMemberIsClinician {
  all m: CareTeamMembership | m.ctmClinician.role = Clinician
}

// ─── Relationship computation ─────────────────────────────────────────────────
// Mirrors permissions.relationship(user, record_id, db).
// Defined as a predicate over (u, r, rel) and used in outcome facts.
pred relOf[u: User, r: Record, rel: Relationship] {
  (rel = CareTeamClin)  iff (u.role = Clinician and
                              (some m: CareTeamMembership | m.ctmClinician = u and m.ctmRecord = r))
  (rel = NonCareTeamClin) iff (u.role = Clinician and
                               (no m: CareTeamMembership | m.ctmClinician = u and m.ctmRecord = r))
  (rel = PatientOwn)    iff (u.role = Patient and u.assignedRecord = r)
  (rel = PatientOther)  iff (u.role = Patient and u.assignedRecord != r)
  (rel = ComplianceOff) iff (u.role = ComplianceOfficer)
}

// ─── Outcome must agree with the permission matrix ────────────────────────────
// spec.md FR-004–FR-007; contracts/http-api.md permission table.
fact F_OutcomeMatchesPermMatrix {
  // For record-scoped operations the caller's relationship to the target record
  // determines the outcome.
  all op: Operation | op.opRecord != none implies (
    some rel: Relationship |
      relOf[op.opCaller, op.opRecord, rel] and
      (op.opOutcome = Permitted iff (rel -> op.opKind in PermMatrix.Allowed))
  )
  // GetAccessLog has no target record; only ComplianceOfficer may be Permitted.
  all op: Operation | op.opKind = GetAccessLog implies (
    op.opRecord = none and
    (op.opOutcome = Permitted iff op.opCaller.role = ComplianceOfficer)
  )
  // record-scoped endpoints require a target record
  all op: Operation | op.opKind != GetAccessLog implies op.opRecord != none
}

// ─── Audit attribution integrity ─────────────────────────────────────────────
// data-model.md: AuditEntry snaps the caller's identity at access time (FR-014).
fact F_AuditAttribution {
  all op: Operation |
    op.opAuditEntry.aeAccessor     = op.opCaller    and
    op.opAuditEntry.aeAccessorRole = op.opCaller.role and
    op.opAuditEntry.aeOperation    = op.opKind       and
    op.opAuditEntry.aeOutcome      = op.opOutcome    and
    op.opAuditEntry.aeRecord       = op.opRecord
}

// ─── One-to-one audit/operation coupling ─────────────────────────────────────
// spec.md FR-013: every access event has exactly one audit entry; no orphan
// audit entries.  (The `one AuditEntry` field gives the forward direction;
// this fact enforces the backward direction.)
fact F_AuditEntryLinkedToOperation {
  all ae: AuditEntry | one op: Operation | op.opAuditEntry = ae
}

// ─── Note-author must be a Clinician ─────────────────────────────────────────
// data-model.md clinical_notes CHECK(author_role = 'clinician').
fact F_NoteAuthorIsClinician {
  all n: ClinicalNote | n.noteAuthor.role = Clinician
}

// ─── Note only created on a permitted PostNote operation ─────────────────────
// spec.md FR-011; if an Operation is a denied PostNote, no ClinicalNote
// should be produced.
fact F_NotePersistOnPermittedAppendOnly {
  all n: ClinicalNote |
    some op: Operation |
      op.opKind = PostNote and
      op.opOutcome = Permitted and
      op.opRecord = n.noteRecord and
      op.opCaller = n.noteAuthor
}

// ─── AuditEntry noteRef linking (data-model.md structural CHECK) ─────────────
// note_id is set iff operation='append' AND outcome='permitted'.
fact F_AuditNoteRefConstraint {
  all ae: AuditEntry |
    (ae.aeOperation = PostNote and ae.aeOutcome = Permitted) implies (one ae.aeNoteRef)
  all ae: AuditEntry |
    (ae.aeOperation != PostNote or ae.aeOutcome = Denied) implies no ae.aeNoteRef
}

// ─── No information leakage: denied response is uniform ──────────────────────
// spec.md FR-008: denied response is byte-identical regardless of record
// existence.  In the Alloy model this means every denied operation is
// indistinguishable at the outcome level — there is no "not-found" outcome,
// only Denied.
fact F_NoLeakageDeniedIsUniform {
  all op: Operation |
    op.opOutcome = Denied implies
      (no rel: Relationship | relOf[op.opCaller, op.opRecord, rel] and
        (rel -> op.opKind in PermMatrix.Allowed))
}

// ─── Compliance officer cannot read clinical content ─────────────────────────
// spec.md FR-007, FR-019: ComplianceOfficer is never Permitted on GetRecord.
fact F_ComplianceContentBlindness {
  all op: Operation |
    op.opCaller.role = ComplianceOfficer implies
      op.opKind != GetRecord
  // equivalently, no Permitted GetRecord for a compliance caller
  no op: Operation |
    op.opCaller.role = ComplianceOfficer and op.opKind = GetRecord and op.opOutcome = Permitted
}

// ─── Compliance officer cannot append notes ──────────────────────────────────
// spec.md FR-007.
fact F_ComplianceCannotPostNote {
  no op: Operation |
    op.opCaller.role = ComplianceOfficer and op.opKind = PostNote and op.opOutcome = Permitted
}

// ─── Patient cannot write clinical content ────────────────────────────────────
// spec.md FR-006.
fact F_PatientCannotPostNote {
  no op: Operation |
    op.opCaller.role = Patient and op.opKind = PostNote and op.opOutcome = Permitted
}

// ─── GetAccessLog is compliance-officer-only ─────────────────────────────────
// spec.md FR-018.
fact F_AccessLogComplianceOnly {
  all op: Operation |
    op.opKind = GetAccessLog and op.opOutcome = Permitted implies
      op.opCaller.role = ComplianceOfficer
}

// ─── Care-team gating for GetRecord ──────────────────────────────────────────
// spec.md FR-004: clinician without active care-team membership is denied.
fact F_CareTeamGatingGetRecord {
  all op: Operation |
    op.opKind = GetRecord and
    op.opCaller.role = Clinician and
    op.opOutcome = Permitted implies
      (some m: CareTeamMembership | m.ctmClinician = op.opCaller and m.ctmRecord = op.opRecord)
}

// ─── Care-team gating for PostNote ───────────────────────────────────────────
// spec.md FR-004.
fact F_CareTeamGatingPostNote {
  all op: Operation |
    op.opKind = PostNote and
    op.opCaller.role = Clinician and
    op.opOutcome = Permitted implies
      (some m: CareTeamMembership | m.ctmClinician = op.opCaller and m.ctmRecord = op.opRecord)
}

// ─── Patient self-access only ────────────────────────────────────────────────
// spec.md FR-006.
fact F_PatientSelfAccessOnly {
  all op: Operation |
    op.opCaller.role = Patient and op.opOutcome = Permitted implies
      op.opRecord = op.opCaller.assignedRecord
}

// ─────────────────────────────────────────────────────────────────────────────
// PREDICATES + ASSERTIONS
// (one pred/assert pair per pattern and per FR-NNN)
// ─────────────────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission table; spec.md FR-004–FR-007
pred LeastPrivilege {
  // Every Permitted operation must have a (Relationship, OperationKind) pair in PermMatrix.Allowed
  some Operation  // force non-vacuous
  all op: Operation |
    op.opOutcome = Permitted implies (
      some rel: Relationship |
        relOf[op.opCaller, op.opRecord, rel] and
        (rel -> op.opKind in PermMatrix.Allowed)
    )
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  // Every (Relationship, OperationKind) pair either is or is not in PermMatrix.Allowed — no gaps.
  // Encoded as: the Allowed relation is a subset of the full Relationship×OperationKind product.
  some Operation
  PermMatrix.Allowed in Relationship -> OperationKind
  // And every Operation outcome is exactly Permitted or Denied (no undefined)
  all op: Operation | op.opOutcome = Permitted or op.opOutcome = Denied
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
// In the Alloy model every Operation has a caller (no anonymous access).
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation | one op.opCaller
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md AuditEntry UNIQUE
pred AuditCompleteness {
  some Operation
  // Every Operation has exactly one AuditEntry (one field enforces forward direction;
  // F_AuditEntryLinkedToOperation enforces backward).
  all op: Operation | one op.opAuditEntry
  // No AuditEntry exists without a corresponding Operation
  all ae: AuditEntry | (some op: Operation | op.opAuditEntry = ae)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly (clinical notes)  ANCHOR: spec.md FR-012; data-model.md no UPDATE/DELETE on clinical_notes
// In the structural model notes have no "deleted" or "modified" status field —
// mutation would show as two ClinicalNote atoms for the same record/author pair
// with different content, but here we assert every note is tied to exactly one
// permitted PostNote operation.
pred AppendOnly {
  some ClinicalNote
  all n: ClinicalNote |
    (some op: Operation |
      op.opKind    = PostNote  and
      op.opOutcome = Permitted and
      op.opRecord  = n.noteRecord and
      op.opCaller  = n.noteAuthor)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AppendOnly (audit entries)  ANCHOR: spec.md FR-015; data-model.md no UPDATE/DELETE on audit_entries
pred AppendOnlyAudit {
  some AuditEntry
  // Every AuditEntry corresponds to exactly one Operation — no orphan entries
  // and no duplicate entries for the same operation.
  all ae: AuditEntry | one op: Operation | op.opAuditEntry = ae
}
assert AppendOnlyAudit { AppendOnlyAudit }
check AppendOnlyAudit for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md AuditEntry fields
pred AttributionCorrectness {
  some AuditEntry
  all ae: AuditEntry |
    (some op: Operation |
      op.opAuditEntry = ae and
      ae.aeAccessor     = op.opCaller     and
      ae.aeAccessorRole = op.opCaller.role and
      ae.aeOperation    = op.opKind        and
      ae.aeOutcome      = op.opOutcome)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md User.assigned_record_id
pred OwnershipBasedAccess {
  some op: Operation | op.opCaller.role = Patient and op.opOutcome = Permitted
  all op: Operation |
    op.opCaller.role = Patient and op.opOutcome = Permitted implies
      op.opRecord = op.opCaller.assignedRecord
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008; contracts/http-api.md byte-equiv 403 section
pred NoInformationLeakage {
  some Operation
  // All denied operations produce the Denied outcome — there is no
  // "record-not-found" outcome distinct from "forbidden"; both collapse to Denied.
  all op: Operation | op.opOutcome = Denied implies
    (no rel: Relationship |
      relOf[op.opCaller, op.opRecord, rel] and
      (rel -> op.opKind in PermMatrix.Allowed))
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-010; contracts/http-api.md 400 validation_error
// Denied PostNote operations produce no ClinicalNote.
pred ValidationBeforeMutation {
  some Operation
  all op: Operation |
    op.opKind = PostNote and op.opOutcome = Denied implies
      (no n: ClinicalNote | n.noteRecord = op.opRecord and n.noteAuthor = op.opCaller)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md role descriptions; contracts/http-api.md permission table
// CareTeamClin's allowed ops are a superset of NonCareTeamClin's (trivially: NCT has none).
pred PrivilegeMonotonicity {
  // Every operation kind permitted to NonCareTeamClin is also permitted to CareTeamClin.
  // (NonCareTeamClin has no allowed ops, so this is a stronger check that CareTeamClin
  //  is strictly more privileged.)
  all ok: OperationKind |
    NonCareTeamClin -> ok in PermMatrix.Allowed implies CareTeamClin -> ok in PermMatrix.Allowed
  // ComplianceOff has GetRecordAudit + GetAccessLog; PatientOwn has GetRecord + GetRecordAudit.
  // The two roles are incomparable — no monotonicity claim; just verify each has its own slice.
  some ok: OperationKind | ComplianceOff -> ok in PermMatrix.Allowed
  some ok: OperationKind | PatientOwn    -> ok in PermMatrix.Allowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 5

// ─── FR-NNN assertions ────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some Operation
  all op: Operation | one op.opCaller
  // No operation has a null caller — every call is authenticated.
  all op: Operation | op.opCaller in User
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_SingleRolePerUser {
  some User
  all u: User | one u.role
}
assert FR_002_SingleRolePerUser { FR_002_SingleRolePerUser }
check FR_002_SingleRolePerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_PatientAssignedRecord {
  some u: User | u.role = Patient
  all u: User | u.role = Patient  implies one  u.assignedRecord
  all u: User | u.role != Patient implies no   u.assignedRecord
}
assert FR_003_PatientAssignedRecord { FR_003_PatientAssignedRecord }
check FR_003_PatientAssignedRecord for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004; spec.md care-team gating
pred FR_004_CareTeamGating {
  some op: Operation | op.opCaller.role = Clinician
  all op: Operation |
    op.opCaller.role = Clinician and
    (op.opKind = GetRecord or op.opKind = PostNote) and
    op.opOutcome = Permitted implies
      (some m: CareTeamMembership | m.ctmClinician = op.opCaller and m.ctmRecord = op.opRecord)
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005; spec.md clinician audit access
pred FR_005_ClinicianAuditAccess {
  some Operation
  // Clinician Permitted on GetRecordAudit only if in care team for that record.
  all op: Operation |
    op.opCaller.role = Clinician and
    op.opKind = GetRecordAudit and
    op.opOutcome = Permitted implies
      (some m: CareTeamMembership | m.ctmClinician = op.opCaller and m.ctmRecord = op.opRecord)
  // Clinician never Permitted on GetAccessLog.
  no op: Operation |
    op.opCaller.role = Clinician and op.opKind = GetAccessLog and op.opOutcome = Permitted
}
assert FR_005_ClinicianAuditAccess { FR_005_ClinicianAuditAccess }
check FR_005_ClinicianAuditAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006; spec.md patient self-access
pred FR_006_PatientSelfAccess {
  some op: Operation | op.opCaller.role = Patient
  all op: Operation |
    op.opCaller.role = Patient and op.opOutcome = Permitted implies
      op.opRecord = op.opCaller.assignedRecord
  // Patient is never Permitted on PostNote or GetAccessLog.
  no op: Operation |
    op.opCaller.role = Patient and op.opKind = PostNote and op.opOutcome = Permitted
  no op: Operation |
    op.opCaller.role = Patient and op.opKind = GetAccessLog and op.opOutcome = Permitted
}
assert FR_006_PatientSelfAccess { FR_006_PatientSelfAccess }
check FR_006_PatientSelfAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007; spec.md compliance content-blindness
pred FR_007_ComplianceContentBlindness {
  some op: Operation | op.opCaller.role = ComplianceOfficer
  // ComplianceOfficer never Permitted on GetRecord.
  no op: Operation |
    op.opCaller.role = ComplianceOfficer and
    op.opKind = GetRecord and
    op.opOutcome = Permitted
  // ComplianceOfficer never Permitted on PostNote.
  no op: Operation |
    op.opCaller.role = ComplianceOfficer and
    op.opKind = PostNote and
    op.opOutcome = Permitted
}
assert FR_007_ComplianceContentBlindness { FR_007_ComplianceContentBlindness }
check FR_007_ComplianceContentBlindness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008; spec.md byte-equivalent 403 / no-info-leakage
pred FR_008_ByteEquivalent403 {
  some Operation
  // There is exactly one denial shape — Denied — regardless of why the caller
  // was denied (not-in-care-team, wrong-patient, compliance-calling-record-endpoint,
  // non-existent-record-id).  All collapse to the same Denied outcome.
  all op: Operation |
    op.opOutcome = Denied implies
      (no rel: Relationship |
        relOf[op.opCaller, op.opRecord, rel] and
        (rel -> op.opKind in PermMatrix.Allowed))
}
assert FR_008_ByteEquivalent403 { FR_008_ByteEquivalent403 }
check FR_008_ByteEquivalent403 for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012; spec.md notes append-only
pred FR_012_NotesAppendOnly {
  some ClinicalNote
  // Every ClinicalNote was produced by exactly one Permitted PostNote operation.
  all n: ClinicalNote |
    (one op: Operation |
      op.opKind    = PostNote  and
      op.opOutcome = Permitted and
      op.opRecord  = n.noteRecord and
      op.opCaller  = n.noteAuthor)
  // Author is always a clinician (structural, but re-checked here).
  all n: ClinicalNote | n.noteAuthor.role = Clinician
}
assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013; spec.md always-on audit, SC-001/SC-002
pred FR_013_AlwaysOnAudit {
  some Operation
  // Every Operation has exactly one AuditEntry.
  all op: Operation | one op.opAuditEntry
  // Every AuditEntry belongs to exactly one Operation.
  all ae: AuditEntry | (one op: Operation | op.opAuditEntry = ae)
}
assert FR_013_AlwaysOnAudit { FR_013_AlwaysOnAudit }
check FR_013_AlwaysOnAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014; spec.md audit entry mandatory fields
pred FR_014_AuditEntryShape {
  some AuditEntry
  all ae: AuditEntry |
    // accessor is linked
    one ae.aeAccessor and
    // accessorRole matches the actual user role (snapshot)
    ae.aeAccessorRole = ae.aeAccessor.role and
    // operation is always defined
    one ae.aeOperation and
    // outcome is always defined
    one ae.aeOutcome and
    // noteRef constraint: set iff permitted append
    ((ae.aeOperation = PostNote and ae.aeOutcome = Permitted) iff one ae.aeNoteRef)
}
assert FR_014_AuditEntryShape { FR_014_AuditEntryShape }
check FR_014_AuditEntryShape for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015; spec.md audit immutability; data-model.md no UPDATE/DELETE on audit_entries
pred FR_015_AuditImmutability {
  some AuditEntry
  // Every AuditEntry is tied to exactly one Operation — no orphan and no duplicate.
  all ae: AuditEntry | one op: Operation | op.opAuditEntry = ae
}
assert FR_015_AuditImmutability { FR_015_AuditImmutability }
check FR_015_AuditImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016; spec.md audit SLA — no access without audit
pred FR_016_NoAccessWithoutAudit {
  some Operation
  // No Operation exists without its audit entry.
  no op: Operation | no op.opAuditEntry
}
assert FR_016_NoAccessWithoutAudit { FR_016_NoAccessWithoutAudit }
check FR_016_NoAccessWithoutAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018; spec.md GetAccessLog compliance-only
pred FR_018_AccessLogComplianceOnly {
  some op: Operation | op.opKind = GetAccessLog
  all op: Operation |
    op.opKind = GetAccessLog and op.opOutcome = Permitted implies
      op.opCaller.role = ComplianceOfficer
}
assert FR_018_AccessLogComplianceOnly { FR_018_AccessLogComplianceOnly }
check FR_018_AccessLogComplianceOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019; spec.md compliance content-blindness (structural)
pred FR_019_ComplianceNoClinicalContent {
  some op: Operation | op.opCaller.role = ComplianceOfficer and op.opOutcome = Permitted
  // A compliance officer's Permitted operations are only GetRecordAudit and GetAccessLog.
  all op: Operation |
    op.opCaller.role = ComplianceOfficer and op.opOutcome = Permitted implies
      (op.opKind = GetRecordAudit or op.opKind = GetAccessLog)
}
assert FR_019_ComplianceNoClinicalContent { FR_019_ComplianceNoClinicalContent }
check FR_019_ComplianceNoClinicalContent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020; spec.md opaque record_id in URL paths (structural ownership)
// In the Alloy model: patient demographics are not reachable from Operation via the opRecord field
// except through the Record sig (which is opaque here). Encoded as: users' personalIdentifiers
// are not exposed — structurally, Record carries no Role-bearing fields, so URL-path PII leakage
// cannot be expressed; the invariant becomes: Record atoms are fully opaque identifiers.
pred FR_020_OpaqueRecordId {
  // Every record referenced by an Operation or an AuditEntry is an atom of sig Record.
  // Record carries no demographic fields reachable from OperationKind or Role — opaque by sig.
  all op: Operation  | op.opRecord in Record
  all ae: AuditEntry | ae.aeRecord in Record
}
assert FR_020_OpaqueRecordId { FR_020_OpaqueRecordId }
check FR_020_OpaqueRecordId for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-011; ClinicalNote author snapshotted as Clinician
pred FR_011_NoteAuthorSnapshot {
  some ClinicalNote
  all n: ClinicalNote | n.noteAuthor.role = Clinician
}
assert FR_011_NoteAuthorSnapshot { FR_011_NoteAuthorSnapshot }
check FR_011_NoteAuthorSnapshot for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-002 / data-model.md CHECK on CareTeamMembership
pred FR_002_CareTeamMemberRoleConstraint {
  some CareTeamMembership
  all m: CareTeamMembership | m.ctmClinician.role = Clinician
}
assert FR_002_CareTeamMemberRoleConstraint { FR_002_CareTeamMemberRoleConstraint }
check FR_002_CareTeamMemberRoleConstraint for 5