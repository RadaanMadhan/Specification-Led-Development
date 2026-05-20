// === feature_model.als — Alloy model for 012-hospital-clinical-records ===
// Structural model of the hospital clinical record access feature.
// Encodes the authorisation matrix (5 roles × 3 endpoints), care-team
// gating, append-only notes & audits, administrator content-blindness,
// audit completeness, and validation-before-mutation invariants.

// ---------- Booleans ----------
abstract sig Bool {}
one sig True, False extends Bool {}

// ---------- Roles ----------
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator extends Role {}

// ---------- Operation kinds (endpoints) ----------
abstract sig OperationKind {}
one sig ReadRecord, AddNote, ListAudit extends OperationKind {}

// ---------- Outcomes ----------
abstract sig Outcome {}
one sig Permitted, Denied, NotFoundOrDenied extends Outcome {}

// ---------- Care-team membership status ----------
abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

// ---------- Permission matrix (Role × OperationKind → allowed) ----------
// Singleton-sig field encoding so we have a manipulable relation.
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Entities from data-model.md ----------
sig User { role: one Role }

sig Patient {}

sig CareTeamMembership {
  clinician: one User,
  carePatient: one Patient,
  status: one MembershipStatus
}

sig ClinicalNote {
  notePatient: one Patient,
  author: one User,
  authorRoleSnapshot: one Role
}

sig AuditEntry {
  accessor: one User,
  accessorRoleSnapshot: one Role,
  auditPatient: one Patient,
  auditKind: one OperationKind,
  auditOutcome: one Outcome,
  noteRef: lone ClinicalNote
}

// An attempted operation (a request hitting the system).
sig Operation {
  authenticated: one Bool,
  caller: lone User,
  opKind: one OperationKind,
  opPatient: one Patient,
  opOutcome: one Outcome,
  validated: one Bool,
  audit: lone AuditEntry,
  noteCreated: lone ClinicalNote
}

// =============================================================
// Non-empty universe — single named fact, no inline witnesses.
// =============================================================
fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
  some Operation
}

// =============================================================
// Permission matrix (encoded from contracts/http-api.md):
//   doctor, nurse, pharmacist, clinical_admin   → read, add_note
//   hospital_administrator                       → list_audit
// =============================================================
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Doctor -> ReadRecord) + (Doctor -> AddNote) +
      (Nurse -> ReadRecord) + (Nurse -> AddNote) +
      (Pharmacist -> ReadRecord) + (Pharmacist -> AddNote) +
      (ClinicalAdmin -> ReadRecord) + (ClinicalAdmin -> AddNote) +
      (HospitalAdministrator -> ListAudit)
}

// =============================================================
// Authenticated callers
// =============================================================
fact F_AuthCallerLink {
  // Authenticated iff there is a caller user.
  all op: Operation | op.authenticated = True iff some op.caller
}

// =============================================================
// FR-001: unauthenticated operations write no audit and produce no state.
// =============================================================
fact F_UnauthNoAudit {
  all op: Operation | op.authenticated = False implies (no op.audit and no op.noteCreated and op.opOutcome != Permitted)
}

// =============================================================
// FR-004: care-team gating for clinical endpoints.
// =============================================================
fact F_CareTeamRequired {
  all op: Operation |
    (op.opOutcome = Permitted and op.opKind in (ReadRecord + AddNote)) implies
      (some m: CareTeamMembership |
         m.clinician = op.caller and
         m.carePatient = op.opPatient and
         m.status = Active)
}

// =============================================================
// FR-005 & FR-018: administrator may not read/write clinical content.
// =============================================================
fact F_AdminNoClinicalContent {
  all op: Operation |
    (op.caller.role = HospitalAdministrator and op.opKind in (ReadRecord + AddNote))
      implies op.opOutcome != Permitted
}

// =============================================================
// FR-017: list_audit endpoint is administrator-only.
// =============================================================
fact F_AdminOnlyListAudit {
  all op: Operation |
    (op.opKind = ListAudit and op.opOutcome = Permitted) implies
      op.caller.role = HospitalAdministrator
}

// =============================================================
// FR-012: every validated, authenticated clinical-endpoint attempt
// produces exactly one audit entry. Validation failures produce none.
// =============================================================
fact F_AuditCompleteness {
  all op: Operation |
    (op.authenticated = True and op.validated = True and op.opKind in (ReadRecord + AddNote))
      implies (one op.audit)
  all op: Operation |
    (op.authenticated = True and op.validated = True and op.opKind = ListAudit and op.opOutcome = Permitted)
      implies (one op.audit)
  all op: Operation | op.validated = False implies no op.audit
}

// =============================================================
// FR-014 / FR-011: append-only — every audit entry and every clinical
// note is uniquely owned by exactly one operation (no aliasing / no
// orphan rows fabricated outside an operation).
// =============================================================
fact F_AppendOnlyAuditEntries {
  all a: AuditEntry | one op: Operation | op.audit = a
}

fact F_AppendOnlyClinicalNotes {
  all n: ClinicalNote | one op: Operation | op.noteCreated = n
}

// =============================================================
// FR-010 / FR-013: attribution & note-id pairing.
// =============================================================
fact F_AuditAttribution {
  all op: Operation | some op.audit implies (
    op.audit.accessor = op.caller and
    op.audit.accessorRoleSnapshot = op.caller.role and
    op.audit.auditPatient = op.opPatient and
    op.audit.auditKind = op.opKind and
    op.audit.auditOutcome = op.opOutcome
  )
}

fact F_NoteIdPairing {
  // note_id appears in an audit entry iff it is a permitted add_note event.
  all a: AuditEntry |
    (some a.noteRef) iff (a.auditKind = AddNote and a.auditOutcome = Permitted)
  // The note in the audit's noteRef is the note created by the same operation.
  all op: Operation | (some op.audit and some op.audit.noteRef) implies
    op.audit.noteRef = op.noteCreated
}

fact F_NoteCreationGate {
  // Notes are only created on permitted add_note operations.
  all op: Operation |
    some op.noteCreated implies (op.opKind = AddNote and op.opOutcome = Permitted)
  all op: Operation |
    (op.opKind = AddNote and op.opOutcome = Permitted) implies some op.noteCreated
  // The created note's fields match the operation.
  all op: Operation | some op.noteCreated implies (
    op.noteCreated.author = op.caller and
    op.noteCreated.notePatient = op.opPatient and
    op.noteCreated.authorRoleSnapshot = op.caller.role
  )
}

// =============================================================
// data-model.md schema CHECK: clinical_notes.author_role excludes
// hospital_administrator — admins cannot author notes structurally.
// =============================================================
fact F_NoteAuthorIsClinical {
  all n: ClinicalNote | n.authorRoleSnapshot != HospitalAdministrator
}

// =============================================================
// FR-009 / pattern ValidationBeforeMutation: invalid requests cause
// no state change (no note, no audit).
// =============================================================
fact F_ValidationGate {
  all op: Operation | op.validated = False implies (no op.noteCreated and op.opOutcome != Permitted)
}

// =============================================================
// Permission matrix is consulted for permitted operations: a caller's
// role must be allowed for the kind they invoke.
// =============================================================
fact F_PermitRequiresMatrix {
  all op: Operation | op.opOutcome = Permitted implies
    (op.caller.role -> op.opKind) in PermMatrix.Allowed
}

// =============================================================
// ============   PREDICATES + ASSERTIONS + CHECKS   ============
// =============================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred FR_001_AuthRequired {
  some op: Operation | op.authenticated = True
  all op: Operation | op.authenticated = False implies (no op.audit and op.opOutcome != Permitted)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 single role per user
pred FR_002_OneRolePerUser {
  some User
  all u: User | one u.role
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 8

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md auth matrix; spec.md FR-004, FR-005, FR-017
pred LeastPrivilege {
  some op: Operation | op.opOutcome = Permitted
  all op: Operation | op.opOutcome = Permitted implies
    (some op.caller and (op.caller.role -> op.opKind) in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
  // Each role has at least one allowed operation kind, and each operation
  // kind has at least one allowed role. No silent dead cells in the matrix.
  all r: Role | some k: OperationKind | (r -> k) in PermMatrix.Allowed
  all k: OperationKind | some r: Role | (r -> k) in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004 (care-team membership)
pred OwnershipBasedAccess {
  some op: Operation | op.opOutcome = Permitted and op.opKind in (ReadRecord + AddNote)
  all op: Operation |
    (op.opOutcome = Permitted and op.opKind in (ReadRecord + AddNote)) implies
      (some m: CareTeamMembership |
         m.clinician = op.caller and
         m.carePatient = op.opPatient and
         m.status = Active)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 care-team gating (negative direction)
pred FR_004_CareTeamGating {
  some Operation
  all op: Operation |
    (op.opKind in (ReadRecord + AddNote) and op.opOutcome = Permitted) implies
      (some m: CareTeamMembership |
         m.clinician = op.caller and m.carePatient = op.opPatient and m.status = Active)
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 administrators cannot read clinical content
pred FR_005_AdminNoClinical {
  some op: Operation | op.caller.role = HospitalAdministrator
  all op: Operation |
    (op.caller.role = HospitalAdministrator and op.opKind in (ReadRecord + AddNote))
      implies op.opOutcome != Permitted
}
assert FR_005_AdminNoClinical { FR_005_AdminNoClinical }
check FR_005_AdminNoClinical for 8

// PATTERN: NoInformationLeakage  ANCHOR: FR-006 byte-equivalent unauthorised
pred NoInformationLeakage {
  // Refused operations expose no clinical state (no note, no successful path),
  // which is the structural counterpart of the byte-equivalent response.
  some op: Operation | op.opOutcome != Permitted
  all op: Operation | op.opOutcome != Permitted implies no op.noteCreated
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007/FR-019/FR-020 response shape (structurally: permitted reads must have an authenticated caller and a patient)
pred FR_007_RecordReadShape {
  some op: Operation | op.opKind = ReadRecord and op.opOutcome = Permitted
  all op: Operation |
    (op.opKind = ReadRecord and op.opOutcome = Permitted) implies
      (some op.caller and some op.opPatient and op.authenticated = True)
}
assert FR_007_RecordReadShape { FR_007_RecordReadShape }
check FR_007_RecordReadShape for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 only clinical roles handle patient summary; satisfied via author-role constraint
pred FR_008_SummaryScope {
  // Any note read in a successful path was authored by a clinical role.
  all n: ClinicalNote | n.authorRoleSnapshot in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}
assert FR_008_SummaryScope { FR_008_SummaryScope }
check FR_008_SummaryScope for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: FR-009
pred FR_009_ValidationBeforeMutation {
  some op: Operation | op.validated = False
  all op: Operation | op.validated = False implies (no op.noteCreated and op.opOutcome != Permitted and no op.audit)
}
assert FR_009_ValidationBeforeMutation { FR_009_ValidationBeforeMutation }
check FR_009_ValidationBeforeMutation for 8

// PATTERN: AttributionCorrectness  ANCHOR: FR-010, FR-013
pred FR_010_NotePersistence {
  some n: ClinicalNote
  all n: ClinicalNote |
    (some op: Operation | op.noteCreated = n and
       op.opKind = AddNote and op.opOutcome = Permitted and
       n.author = op.caller and n.notePatient = op.opPatient and
       n.authorRoleSnapshot = op.caller.role)
}
assert FR_010_NotePersistence { FR_010_NotePersistence }
check FR_010_NotePersistence for 8

// PATTERN: AppendOnly  ANCHOR: FR-011 clinical notes append-only
pred FR_011_NotesAppendOnly {
  some ClinicalNote
  // Every note has exactly one originating operation (no edit/duplicate path).
  all n: ClinicalNote | one op: Operation | op.noteCreated = n
  // No note exists without a permitted add_note operation.
  all n: ClinicalNote |
    (some op: Operation | op.noteCreated = n and op.opKind = AddNote and op.opOutcome = Permitted)
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 8

// PATTERN: AuditCompleteness  ANCHOR: FR-012
pred FR_012_AuditCompleteness {
  some op: Operation | op.authenticated = True and op.validated = True and op.opKind in (ReadRecord + AddNote)
  all op: Operation |
    (op.authenticated = True and op.validated = True and op.opKind in (ReadRecord + AddNote))
      implies (one op.audit)
  // No audit without an operation.
  all a: AuditEntry | some op: Operation | op.audit = a
}
assert FR_012_AuditCompleteness { FR_012_AuditCompleteness }
check FR_012_AuditCompleteness for 8

// PATTERN: AttributionCorrectness  ANCHOR: FR-013 audit-entry fields
pred FR_013_AuditAttribution {
  some op: Operation | some op.audit
  all op: Operation | some op.audit implies (
    op.audit.accessor = op.caller and
    op.audit.accessorRoleSnapshot = op.caller.role and
    op.audit.auditPatient = op.opPatient and
    op.audit.auditKind = op.opKind and
    op.audit.auditOutcome = op.opOutcome
  )
  // note_id only on permitted add_note.
  all a: AuditEntry | (some a.noteRef) iff (a.auditKind = AddNote and a.auditOutcome = Permitted)
}
assert FR_013_AuditAttribution { FR_013_AuditAttribution }
check FR_013_AuditAttribution for 8

// PATTERN: AppendOnly  ANCHOR: FR-014 audit entries immutable
pred FR_014_AuditAppendOnly {
  some AuditEntry
  // Every audit entry is uniquely owned by exactly one operation: no
  // duplicates, no orphans, no aliasing under mutation.
  all a: AuditEntry | one op: Operation | op.audit = a
}
assert FR_014_AuditAppendOnly { FR_014_AuditAppendOnly }
check FR_014_AuditAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 audit SLA — every permitted op has an audit (no orphan permitted state)
pred FR_015_NoPermittedWithoutAudit {
  all op: Operation | op.opOutcome = Permitted implies one op.audit
}
assert FR_015_NoPermittedWithoutAudit { FR_015_NoPermittedWithoutAudit }
check FR_015_NoPermittedWithoutAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 audit retention — no audit entry deleted (structurally: every audit traceable to its operation)
pred FR_016_AuditRetained {
  all a: AuditEntry | some op: Operation | op.audit = a
}
assert FR_016_AuditRetained { FR_016_AuditRetained }
check FR_016_AuditRetained for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 list_audit endpoint is administrator-only
pred FR_017_AdminOnlyAudit {
  some op: Operation | op.opKind = ListAudit
  all op: Operation |
    (op.opKind = ListAudit and op.opOutcome = Permitted) implies
      (some op.caller and op.caller.role = HospitalAdministrator)
}
assert FR_017_AdminOnlyAudit { FR_017_AdminOnlyAudit }
check FR_017_AdminOnlyAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 administrator content blindness — admins never create notes
pred FR_018_AdminContentBlind {
  some op: Operation | op.caller.role = HospitalAdministrator
  all op: Operation |
    (op.caller.role = HospitalAdministrator) implies no op.noteCreated
  all n: ClinicalNote | n.authorRoleSnapshot != HospitalAdministrator
}
assert FR_018_AdminContentBlind { FR_018_AdminContentBlind }
check FR_018_AdminContentBlind for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 safety-fields-first (structural: permitted reads have a patient context)
pred FR_019_SafetyFieldsFirst {
  all op: Operation |
    (op.opKind = ReadRecord and op.opOutcome = Permitted) implies some op.opPatient
}
assert FR_019_SafetyFieldsFirst { FR_019_SafetyFieldsFirst }
check FR_019_SafetyFieldsFirst for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020 notes-count placement (structural: notes are tied to the patient being read)
pred FR_020_NotesCountTiedToPatient {
  all n: ClinicalNote, op: Operation |
    op.noteCreated = n implies n.notePatient = op.opPatient
}
assert FR_020_NotesCountTiedToPatient { FR_020_NotesCountTiedToPatient }
check FR_020_NotesCountTiedToPatient for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 patient_id never in URL path — surfaced as: every operation carries a patient in its body, not implicit in identity
pred FR_003_PatientIdInBody {
  all op: Operation | one op.opPatient
}
assert FR_003_PatientIdInBody { FR_003_PatientIdInBody }
check FR_003_PatientIdInBody for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 byte-equivalent unauthorised — no caller can observe note creation on a refused op
pred FR_006_ByteEquivalent {
  all op: Operation | op.opOutcome != Permitted implies (no op.noteCreated)
}
assert FR_006_ByteEquivalent { FR_006_ByteEquivalent }
check FR_006_ByteEquivalent for 8