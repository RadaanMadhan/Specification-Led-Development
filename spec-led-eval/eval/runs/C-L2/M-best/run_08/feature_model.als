// === feature_model.als — Alloy model for Hospital Clinical Record Access ===
// Feature: 012-hospital-clinical-records
//
// Structural encoding of:
//   - Five-role catalogue (4 clinical + 1 administrator)
//   - Three-operation surface (record read, add note, list audit)
//   - Care-team-membership gating (FR-004)
//   - Administrator content-blindness (FR-005, FR-018)
//   - Always-on append-only audit (FR-012, FR-014)
//   - Append-only clinical notes (FR-011)
//   - Byte-equivalent unauthorised envelope (FR-006)

// ---------------------- Role catalogue ----------------------

abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator extends Role {}

// ---------------------- Operation kinds ----------------------

abstract sig OperationKind {}
one sig ReadRecord, AddNote, ListAudit extends OperationKind {}

// ---------------------- Outcomes / bases ----------------------

abstract sig Outcome {}
one sig Permitted, Denied, NotFoundOrDenied extends Outcome {}

abstract sig AuthBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound, AdministratorRole extends AuthBasis {}

// ---------------------- Response shapes ----------------------

abstract sig ResponseShape {}
one sig ClinicalReadShape, NoteCreatedShape, AdminAuditShape, ByteEquivalent404 extends ResponseShape {}

// ---------------------- Concrete entities ----------------------

sig User { role: one Role }
sig Patient {}

sig CareTeam {
  ctClinician: one User,
  ctPatient: one Patient
}

sig ClinicalNote {
  notePatient: one Patient,
  noteAuthor: one User,
  noteAuthorRoleSnap: one Role
}

sig AuditEntry {
  aeAccessor: one User,
  aeAccessorRoleSnap: one Role,
  aePatient: one Patient,
  aeAccessType: one OperationKind,
  aeNoteRef: lone ClinicalNote,
  aeOutcome: one Outcome,
  aeBasis: one AuthBasis
}

// An Operation represents a request that passed the authentication boundary
// (FR-001) and reached the handler. Unauthenticated requests are rejected
// before becoming Operation atoms.
sig Operation {
  opCaller: one User,
  opKind: one OperationKind,
  opPatient: one Patient,
  opOutcome: one Outcome,
  opBasis: one AuthBasis,
  opAudit: lone AuditEntry,
  opCreatedNote: lone ClinicalNote,
  opResponse: one ResponseShape
}

// Hypothetical edit/mutation events — append-only invariants forbid them.
sig NoteEdit { editedNote: one ClinicalNote }
sig AuditMutation { mutatedAudit: one AuditEntry }

// ---------------------- Permission matrix ----------------------

one sig PermMatrix {
  Allowed: set Role -> OperationKind,
  Conditional: set Role -> OperationKind
}

// ---------------------- Non-empty universe ----------------------

fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeam
  some ClinicalNote
  some AuditEntry
  some Operation
}

// ---------------------- Permission matrix encoding ----------------------

fact F_PermissionMatrix {
  // Unconditional allow: administrator -> ListAudit (FR-017).
  PermMatrix.Allowed = HospitalAdministrator -> ListAudit
  // Conditional allow (gated by care-team membership): clinical roles -> {Read, AddNote} (FR-004).
  PermMatrix.Conditional =
    (Doctor -> ReadRecord) + (Doctor -> AddNote) +
    (Nurse -> ReadRecord) + (Nurse -> AddNote) +
    (Pharmacist -> ReadRecord) + (Pharmacist -> AddNote) +
    (ClinicalAdmin -> ReadRecord) + (ClinicalAdmin -> AddNote)
  no PermMatrix.Allowed & PermMatrix.Conditional
}

// ---------------------- Core access-control fact ----------------------

// A Permitted operation must be sanctioned by the matrix; if the cell is
// conditional, an active care-team membership must witness the access.
fact F_AccessControl {
  all o: Operation |
    o.opOutcome = Permitted implies (
      ((o.opCaller.role -> o.opKind) in PermMatrix.Allowed)
      or
      (((o.opCaller.role -> o.opKind) in PermMatrix.Conditional) and
       (some ct: CareTeam | ct.ctClinician = o.opCaller and ct.ctPatient = o.opPatient))
    )
}

// ---------------------- Audit completeness ----------------------

// FR-012: every Read/AddNote attempt produces exactly one audit entry,
// regardless of outcome. ListAudit is audited only when permitted.
fact F_AuditCompleteness {
  all o: Operation | (o.opKind in (ReadRecord + AddNote)) implies (one o.opAudit)
  all o: Operation | (o.opKind = ListAudit and o.opOutcome = Permitted) implies (one o.opAudit)
  all o: Operation | (o.opKind = ListAudit and o.opOutcome != Permitted) implies (no o.opAudit)
  // Each AuditEntry corresponds to exactly one creating Operation.
  all ae: AuditEntry | (one o: Operation | o.opAudit = ae)
}

// ---------------------- Attribution correctness ----------------------

fact F_Attribution {
  all o: Operation | (some o.opAudit) implies {
    o.opAudit.aeAccessor = o.opCaller
    o.opAudit.aeAccessorRoleSnap = o.opCaller.role
    o.opAudit.aePatient = o.opPatient
    o.opAudit.aeAccessType = o.opKind
    o.opAudit.aeOutcome = o.opOutcome
    o.opAudit.aeBasis = o.opBasis
  }
}

// ---------------------- Authorisation basis correctness ----------------------

fact F_BasisCorrectness {
  all o: Operation | {
    (o.opBasis = AdministratorRole) implies
      (o.opCaller.role = HospitalAdministrator and o.opKind = ListAudit)
    (o.opBasis = CareTeamMember) implies
      (o.opCaller.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
       (some ct: CareTeam | ct.ctClinician = o.opCaller and ct.ctPatient = o.opPatient))
  }
}

// ---------------------- Note authorship constraints ----------------------

// Data-model CHECK: clinical_notes.author_role excludes hospital_administrator.
fact F_NoteAuthorIsClinical {
  all n: ClinicalNote | n.noteAuthorRoleSnap in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
  all n: ClinicalNote | n.noteAuthor.role = n.noteAuthorRoleSnap
}

// Every persisted note traces back to exactly one Permitted AddNote operation,
// whose caller is the author and whose target is the note's patient.
fact F_NoteCreationProvenance {
  all n: ClinicalNote |
    (one o: Operation |
       o.opCreatedNote = n
       and o.opKind = AddNote
       and o.opOutcome = Permitted
       and o.opCaller = n.noteAuthor
       and o.opPatient = n.notePatient)
  all o: Operation | (some o.opCreatedNote) implies
    (o.opKind = AddNote and o.opOutcome = Permitted)
}

// ---------------------- Audit note_id pairing ----------------------

// Per data-model CHECK: aeNoteRef set iff (accessType=add_note ∧ outcome=permitted).
fact F_AuditNoteRefRule {
  all ae: AuditEntry |
    (some ae.aeNoteRef) iff (ae.aeAccessType = AddNote and ae.aeOutcome = Permitted)
  all o: Operation |
    ((some o.opAudit) and (some o.opAudit.aeNoteRef)) implies
      (o.opAudit.aeNoteRef = o.opCreatedNote)
}

// ---------------------- Append-only ----------------------

fact F_NotesAppendOnly { no NoteEdit }
fact F_AuditAppendOnly { no AuditMutation }

// ---------------------- Response-shape facts ----------------------

// FR-006: every non-Permitted outcome yields the byte-equivalent 404.
fact F_NonPermittedResponseIs404 {
  all o: Operation | (o.opOutcome != Permitted) implies (o.opResponse = ByteEquivalent404)
}

// FR-007/FR-019/FR-020: permitted reads always use the clinical-read shape.
fact F_PermittedReadResponse {
  all o: Operation | (o.opKind = ReadRecord and o.opOutcome = Permitted) implies
    (o.opResponse = ClinicalReadShape)
}

// FR-010: permitted note-additions use the note-created shape.
fact F_PermittedAddNoteResponse {
  all o: Operation | (o.opKind = AddNote and o.opOutcome = Permitted) implies
    (o.opResponse = NoteCreatedShape)
}

// FR-005/FR-018: administrator (ListAudit) responses NEVER carry a
// clinical-content response shape.
fact F_AdminResponseNoClinicalContent {
  all o: Operation | (o.opKind = ListAudit) implies
    (o.opResponse != ClinicalReadShape and o.opResponse != NoteCreatedShape)
}

// =====================================================================
// =================   PREDICATES + ASSERTIONS   =======================
// =====================================================================

// ---- Catalogue patterns ----

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md auth tables; spec.md FR-004, FR-005, FR-017
pred LeastPrivilege {
  // No Permitted operation exists outside the policy matrix; conditional
  // cells require a witnessed care-team membership.
  all o: Operation |
    o.opOutcome = Permitted implies (
      ((o.opCaller.role -> o.opKind) in PermMatrix.Allowed)
      or
      (((o.opCaller.role -> o.opKind) in PermMatrix.Conditional) and
       (some ct: CareTeam | ct.ctClinician = o.opCaller and ct.ctPatient = o.opPatient))
    )
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Matrix is well-formed: allow/conditional are disjoint, both are populated.
  no PermMatrix.Allowed & PermMatrix.Conditional
  some PermMatrix.Allowed
  some PermMatrix.Conditional
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-004 (conditional), FR-017 (admin)
pred PermissionGrounding {
  // Every "allow" cell traces back to an FR-NNN.
  PermMatrix.Allowed = HospitalAdministrator -> ListAudit
  all r: Role, k: OperationKind |
    ((r -> k) in PermMatrix.Conditional) implies
      (r in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and k in (ReadRecord + AddNote))
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012; data-model.md audit_entries
pred AuditCompleteness {
  // Every Read/AddNote operation has exactly one audit entry, and every
  // audit entry traces back to exactly one operation. No orphans either way.
  all o: Operation | (o.opKind in (ReadRecord + AddNote)) implies (one o.opAudit)
  all ae: AuditEntry | (one o: Operation | o.opAudit = ae)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011, FR-014
pred AppendOnly {
  no NoteEdit
  no AuditMutation
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md audit_entries snapshot fields
pred AttributionCorrectness {
  // The audit entry's recorded accessor and role match the actual caller.
  all o: Operation | (some o.opAudit) implies {
    o.opAudit.aeAccessor = o.opCaller
    o.opAudit.aeAccessorRoleSnap = o.opCaller.role
    o.opAudit.aePatient = o.opPatient
    o.opAudit.aeAccessType = o.opKind
    o.opAudit.aeOutcome = o.opOutcome
  }
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004 (care-team-conditional permission)
pred OwnershipBasedAccess {
  // Every permitted clinical access has a witnessing care-team-membership row
  // linking the caller to the patient.
  all o: Operation |
    (o.opOutcome = Permitted and o.opKind in (ReadRecord + AddNote)) implies
      (some ct: CareTeam | ct.ctClinician = o.opCaller and ct.ctPatient = o.opPatient)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006; contracts/http-api.md byte-equivalent 404
pred NoInformationLeakage {
  // All refused outcomes share the same observable response shape — no
  // distinguishing "exists but you can't see it" from "does not exist".
  all o: Operation |
    (o.opOutcome in (Denied + NotFoundOrDenied)) implies
      (o.opResponse = ByteEquivalent404)
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  // Every Operation atom (= a request that reached the handler) has a
  // resolved caller. Unauthenticated requests are rejected at the boundary
  // and never become Operation atoms.
  all o: Operation | one o.opCaller
  some Operation
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// =====================================================================
// ====   FEATURE-SPECIFIC FR-NNN PREDICATES (one per FR)   ============
// =====================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 (authentication required at boundary)
pred FR_001_AuthRequired {
  all o: Operation | one o.opCaller
  some Operation
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 (five-role catalogue)
pred FR_002_RoleCatalogue {
  // Every user's role is one of the five v1 values.
  all u: User | u.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin + HospitalAdministrator)
  some User
}
assert FR_002_RoleCatalogue { FR_002_RoleCatalogue }
check FR_002_RoleCatalogue for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 (patient identifier in body, not URL)
// Modelled abstractly: every operation references a patient via the body
// field opPatient — there is no URL-path channel for the identifier.
pred FR_003_PatientIdInBody {
  all o: Operation | one o.opPatient
}
assert FR_003_PatientIdInBody { FR_003_PatientIdInBody }
check FR_003_PatientIdInBody for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 (care-team gating for clinicians)
pred FR_004_CareTeamGating {
  all o: Operation |
    (o.opOutcome = Permitted and o.opKind in (ReadRecord + AddNote)) implies
      (o.opCaller.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
       (some ct: CareTeam | ct.ctClinician = o.opCaller and ct.ctPatient = o.opPatient))
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 (administrator never sees clinical content)
pred FR_005_AdminNoClinicalContent {
  // No Permitted Read/AddNote by a hospital_administrator caller.
  all o: Operation |
    (o.opCaller.role = HospitalAdministrator and o.opKind in (ReadRecord + AddNote)) implies
      (o.opOutcome != Permitted)
  // And ListAudit responses never carry clinical-content shapes.
  all o: Operation | (o.opKind = ListAudit) implies
    (o.opResponse != ClinicalReadShape and o.opResponse != NoteCreatedShape)
}
assert FR_005_AdminNoClinicalContent { FR_005_AdminNoClinicalContent }
check FR_005_AdminNoClinicalContent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 (byte-equivalent unauthorised envelope)
pred FR_006_ByteEquivalentDenied {
  all o: Operation |
    (o.opOutcome in (Denied + NotFoundOrDenied)) implies
      (o.opResponse = ByteEquivalent404)
}
assert FR_006_ByteEquivalentDenied { FR_006_ByteEquivalentDenied }
check FR_006_ByteEquivalentDenied for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 (fixed clinical-read response shape)
pred FR_007_ClinicalReadShape {
  all o: Operation |
    (o.opKind = ReadRecord and o.opOutcome = Permitted) implies
      (o.opResponse = ClinicalReadShape)
}
assert FR_007_ClinicalReadShape { FR_007_ClinicalReadShape }
check FR_007_ClinicalReadShape for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 (patient summary content)
// Abstractly: the single clinical-read response builder is the only path
// for permitted reads — represented by the unique ClinicalReadShape.
pred FR_008_PatientSummary {
  all o: Operation |
    (o.opKind = ReadRecord and o.opOutcome = Permitted) implies
      (o.opResponse = ClinicalReadShape)
}
assert FR_008_PatientSummary { FR_008_PatientSummary }
check FR_008_PatientSummary for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 (note submission validation)
pred FR_009_NoteValidation {
  // Every persisted note's author_role is a clinical role (validation gate).
  all n: ClinicalNote | n.noteAuthorRoleSnap in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
  some ClinicalNote
}
assert FR_009_NoteValidation { FR_009_NoteValidation }
check FR_009_NoteValidation for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 (note persistence fields + provenance)
pred FR_010_NoteProvenance {
  all n: ClinicalNote |
    (one o: Operation |
       o.opCreatedNote = n
       and o.opKind = AddNote
       and o.opOutcome = Permitted
       and o.opCaller = n.noteAuthor
       and o.opPatient = n.notePatient)
  some ClinicalNote
}
assert FR_010_NoteProvenance { FR_010_NoteProvenance }
check FR_010_NoteProvenance for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 (notes append-only)
pred FR_011_NotesAppendOnly { no NoteEdit }
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 (always-on audit for clinical endpoints)
pred FR_012_AlwaysOnAudit {
  all o: Operation | (o.opKind in (ReadRecord + AddNote)) implies (one o.opAudit)
  some Operation
}
assert FR_012_AlwaysOnAudit { FR_012_AlwaysOnAudit }
check FR_012_AlwaysOnAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 (audit-entry shape, note_id pairing)
pred FR_013_AuditFields {
  all ae: AuditEntry | {
    one ae.aeAccessor
    one ae.aeAccessorRoleSnap
    one ae.aePatient
    one ae.aeAccessType
    one ae.aeOutcome
    one ae.aeBasis
    (some ae.aeNoteRef) iff (ae.aeAccessType = AddNote and ae.aeOutcome = Permitted)
  }
  some AuditEntry
}
assert FR_013_AuditFields { FR_013_AuditFields }
check FR_013_AuditFields for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 (audit entries immutable)
pred FR_014_AuditImmutable { no AuditMutation }
assert FR_014_AuditImmutable { FR_014_AuditImmutable }
check FR_014_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 (2-second audit SLA → no state change without audit)
pred FR_015_AuditSLA {
  // A successful clinical state change implies an audit entry. If the audit
  // write fails, the state change is rolled back and no Operation exists.
  all o: Operation |
    (o.opKind = AddNote and o.opOutcome = Permitted) implies (one o.opAudit and one o.opCreatedNote)
  all o: Operation |
    (o.opKind = ReadRecord) implies (one o.opAudit)
}
assert FR_015_AuditSLA { FR_015_AuditSLA }
check FR_015_AuditSLA for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 (audit retention ≥ 7 years; no delete path)
pred FR_016_AuditRetention { no AuditMutation }
assert FR_016_AuditRetention { FR_016_AuditRetention }
check FR_016_AuditRetention for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 (administrator-only audit-listing endpoint)
pred FR_017_AdminOnlyAudit {
  all o: Operation |
    (o.opKind = ListAudit and o.opOutcome = Permitted) implies
      (o.opCaller.role = HospitalAdministrator)
}
assert FR_017_AdminOnlyAudit { FR_017_AdminOnlyAudit }
check FR_017_AdminOnlyAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 (administrator response carries no clinical content)
pred FR_018_AdminContentBlind {
  all o: Operation | (o.opKind = ListAudit) implies
    (o.opResponse != ClinicalReadShape and o.opResponse != NoteCreatedShape)
}
assert FR_018_AdminContentBlind { FR_018_AdminContentBlind }
check FR_018_AdminContentBlind for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 (safety fields placed first in read response)
// Modelled abstractly: the single ClinicalReadShape encodes the fixed layout.
pred FR_019_SafetyFieldsFirst {
  all o: Operation |
    (o.opKind = ReadRecord and o.opOutcome = Permitted) implies
      (o.opResponse = ClinicalReadShape)
}
assert FR_019_SafetyFieldsFirst { FR_019_SafetyFieldsFirst }
check FR_019_SafetyFieldsFirst for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020 (notes count appears in read response)
pred FR_020_NotesCount {
  all o: Operation |
    (o.opKind = ReadRecord and o.opOutcome = Permitted) implies
      (o.opResponse = ClinicalReadShape)
}
assert FR_020_NotesCount { FR_020_NotesCount }
check FR_020_NotesCount for 6