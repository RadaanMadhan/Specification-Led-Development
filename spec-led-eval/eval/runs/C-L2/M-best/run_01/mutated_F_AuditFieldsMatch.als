// === feature_model.als — Alloy model for 012-hospital-clinical-records ===
// Self-contained Alloy 6 model of the Hospital Clinical Record Access feature.
// Encodes: role catalogue, permission matrix, care-team gating, append-only
// notes & audit, byte-equivalent denial, administrator content-blindness.

// ---------------------------------------------------------------------------
// Static enums (singleton hierarchies — not dynamic, no witness needed)
// ---------------------------------------------------------------------------

abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator extends Role {}

// The clinical-role set used throughout (FR-002, FR-004).
fun ClinicalRoles: set Role { Doctor + Nurse + Pharmacist + ClinicalAdmin }

abstract sig OperationKind {}
one sig RecordLookup, AddNote, AuditSearch extends OperationKind {}

abstract sig Outcome {}
one sig Permitted, Denied, NotFoundOrDenied extends Outcome {}

abstract sig AuthBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound, AdministratorRole extends AuthBasis {}

// Permission matrix encoded as a field on a singleton sig
// (per the system-prompt's canonical pattern).
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------------------------------------------------------------------------
// Dynamic entities (data-model.md)
// ---------------------------------------------------------------------------

sig User {
  role: one Role
}

sig Patient {}

sig CareTeamMembership {
  ctmClinician: one User,
  ctmPatient: one Patient,
  ctmActive: one Bool
}

sig ClinicalNote {
  notePatient: one Patient,
  noteAuthor: one User,
  noteAuthorRoleSnap: one Role,
  noteModified: one Bool   // models an attempt to edit; spec says always BFalse
}

sig Operation {
  opCaller: one User,
  opKind: one OperationKind,
  opTargetPatient: lone Patient,  // none = patient_id did not resolve
  opOutcome: one Outcome,
  opBasis: one AuthBasis,
  opCreatedNote: lone ClinicalNote,
  opReturnedClinicalContent: one Bool
}

sig AuditEntry {
  aeFor: one Operation,
  aeUserSnap: one User,
  aeRoleSnap: one Role,
  aeKind: one OperationKind,
  aeOutcome: one Outcome,
  aeBasis: one AuthBasis,
  aeNoteId: lone ClinicalNote,
  aeModified: one Bool   // models an attempt to mutate; spec says always BFalse
}

// ---------------------------------------------------------------------------
// Non-empty universe — single declaration per system-prompt rule 9.
// ---------------------------------------------------------------------------

fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some ClinicalNote
  some Operation
  some AuditEntry
}

// ---------------------------------------------------------------------------
// Named facts (each removable by mutation testing)
// ---------------------------------------------------------------------------

// Permission matrix per contracts/http-api.md
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor -> RecordLookup) + (Doctor -> AddNote) +
    (Nurse -> RecordLookup) + (Nurse -> AddNote) +
    (Pharmacist -> RecordLookup) + (Pharmacist -> AddNote) +
    (ClinicalAdmin -> RecordLookup) + (ClinicalAdmin -> AddNote) +
    (HospitalAdministrator -> AuditSearch)
}

// FR-004: clinical role + active care-team membership are necessary for permit.
fact F_CareTeamGating {
  all o: Operation |
    (o.opKind in (RecordLookup + AddNote) and o.opOutcome = Permitted) implies
      (o.opCaller.role in ClinicalRoles and
       (some m: CareTeamMembership |
         m.ctmClinician = o.opCaller and
         m.ctmPatient = o.opTargetPatient and
         m.ctmActive = BTrue))
}

// FR-017: only hospital_administrator can succeed on the audit-search endpoint.
fact F_AdminOnlyAuditSearch {
  all o: Operation |
    (o.opKind = AuditSearch and o.opOutcome = Permitted) implies
      o.opCaller.role = HospitalAdministrator
}

// FR-005 / FR-018: administrator responses contain no clinical content.
fact F_AdminContentBlind {
  all o: Operation |
    o.opCaller.role = HospitalAdministrator implies
      o.opReturnedClinicalContent = BFalse
}

// FR-006: denied / not-found operations return no content and create no note.
fact F_DenialReturnsNothing {
  all o: Operation |
    o.opOutcome != Permitted implies
      (no o.opCreatedNote and o.opReturnedClinicalContent = BFalse)
}

// FR-010: only clinical-role users can author notes (DB CHECK in data-model.md).
fact F_NoteAuthorIsClinical {
  all n: ClinicalNote |
    n.noteAuthorRoleSnap in ClinicalRoles and
    n.noteAuthor.role in ClinicalRoles
}

// FR-010: author-role snapshot matches author's role at write time.
fact F_NoteAuthorRoleSnapshot {
  all n: ClinicalNote | n.noteAuthorRoleSnap = n.noteAuthor.role
}

// FR-009 / FR-010: Permitted AddNote creates a note pinned to caller and target.
fact F_AddNoteCreatesNote {
  all o: Operation |
    (o.opKind = AddNote and o.opOutcome = Permitted) implies
      (some n: ClinicalNote |
        o.opCreatedNote = n and
        n.noteAuthor = o.opCaller and
        n.notePatient = o.opTargetPatient)
}

// FR-009: no note is created except by a Permitted AddNote.
fact F_NoNoteWithoutPermittedAdd {
  all o: Operation |
    some o.opCreatedNote implies (o.opKind = AddNote and o.opOutcome = Permitted)
}

// FR-011: clinical notes are append-only.
fact F_AppendOnlyNotes {
  all n: ClinicalNote | n.noteModified = BFalse
}

// FR-012 / FR-015: every operation is matched by exactly one audit entry.
fact F_OneAuditPerOperation {
  all o: Operation | one ae: AuditEntry | ae.aeFor = o
}

// FR-013: audit fields are faithful snapshots of the operation.
fact F_AuditFieldsMatch { /* MUTATED — body cleared by validator */ }

// FR-014 / FR-016: audit entries are immutable and never deleted.
fact F_AppendOnlyAudit {
  all ae: AuditEntry | ae.aeModified = BFalse
}

// FR-013: authorisation_basis consistent with kind+outcome.
fact F_BasisConsistency {
  all o: Operation |
    (o.opOutcome = Permitted and o.opKind in (RecordLookup + AddNote))
      implies o.opBasis = CareTeamMember
  all o: Operation |
    (o.opOutcome = Permitted and o.opKind = AuditSearch)
      implies o.opBasis = AdministratorRole
}

// FR-007: a successful record read returns the patient summary (clinical content).
fact F_PermittedReadReturnsContent {
  all o: Operation |
    (o.opKind = RecordLookup and o.opOutcome = Permitted) implies
      o.opReturnedClinicalContent = BTrue
}

// ---------------------------------------------------------------------------
// Pattern-based predicates and assertions
// ---------------------------------------------------------------------------

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md auth tables; spec.md FR-004,FR-005,FR-017
pred LeastPrivilege {
  all o: Operation |
    o.opOutcome = Permitted implies
      (o.opCaller.role -> o.opKind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md tables
pred PermissionCompleteness {
  // Clinical roles can do clinical ops, not audit search
  all r: ClinicalRoles |
    (r -> RecordLookup) in PermMatrix.Allowed and
    (r -> AddNote) in PermMatrix.Allowed and
    (r -> AuditSearch) not in PermMatrix.Allowed
  // Administrator: only audit search
  (HospitalAdministrator -> AuditSearch) in PermMatrix.Allowed
  (HospitalAdministrator -> RecordLookup) not in PermMatrix.Allowed
  (HospitalAdministrator -> AddNote) not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012, FR-013; data-model.md audit_entries
pred AuditCompleteness {
  all o: Operation | one ae: AuditEntry | ae.aeFor = o
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011, FR-014, FR-016; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  (no n: ClinicalNote | n.noteModified = BTrue) and
  (no ae: AuditEntry | ae.aeModified = BTrue)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013
pred AttributionCorrectness {
  all ae: AuditEntry |
    ae.aeUserSnap = ae.aeFor.opCaller and
    ae.aeRoleSnap = ae.aeFor.opCaller.role and
    ae.aeKind = ae.aeFor.opKind and
    ae.aeOutcome = ae.aeFor.opOutcome
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md care_team_memberships
pred OwnershipBasedAccess {
  all o: Operation |
    (o.opKind in (RecordLookup + AddNote) and o.opOutcome = Permitted) implies
      (some m: CareTeamMembership |
        m.ctmClinician = o.opCaller and
        m.ctmPatient = o.opTargetPatient and
        m.ctmActive = BTrue)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006, FR-018
pred NoInformationLeakage {
  (all o: Operation |
    o.opOutcome != Permitted implies
      (no o.opCreatedNote and o.opReturnedClinicalContent = BFalse))
  and
  (all o: Operation |
    o.opCaller.role = HospitalAdministrator implies
      o.opReturnedClinicalContent = BFalse)
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-009
pred ValidationBeforeMutation {
  all o: Operation |
    some o.opCreatedNote implies
      (o.opKind = AddNote and o.opOutcome = Permitted)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// ---------------------------------------------------------------------------
// Feature-specific FR predicates (one per FR-NNN)
// ---------------------------------------------------------------------------

// FEATURE-SPECIFIC  ANCHOR: FR-001 (authentication required before any audit)
pred FR_001_AuthRequired {
  // Every audit entry is associated with an Operation that has a resolved caller.
  all ae: AuditEntry | one ae.aeFor.opCaller
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 (exactly one role per user, from fixed catalogue)
pred FR_002_OneRolePerUser {
  all u: User | one u.role
  all u: User | u.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin + HospitalAdministrator)
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 (patient_id is not part of operation routing)
pred FR_003_NoPatientIdInRoute {
  // Routing is determined by opKind alone — operations of the same kind on different
  // patients are structurally indistinguishable in the routing dimension.
  all o: Operation | one o.opKind
}
assert FR_003_NoPatientIdInRoute { FR_003_NoPatientIdInRoute }
check FR_003_NoPatientIdInRoute for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 (care-team gating for clinical access)
pred FR_004_CareTeamGating {
  all o: Operation |
    (o.opOutcome = Permitted and o.opKind in (RecordLookup + AddNote)) implies
      (o.opCaller.role in ClinicalRoles and
       (some m: CareTeamMembership |
         m.ctmClinician = o.opCaller and
         m.ctmPatient = o.opTargetPatient and
         m.ctmActive = BTrue))
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 (admin cannot read clinical content)
pred FR_005_AdminNoClinicalContent {
  all o: Operation |
    o.opCaller.role = HospitalAdministrator implies
      o.opReturnedClinicalContent = BFalse
}
assert FR_005_AdminNoClinicalContent { FR_005_AdminNoClinicalContent }
check FR_005_AdminNoClinicalContent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 (byte-equivalent denial — no observable difference)
pred FR_006_ByteEquivalentDenial {
  all o: Operation |
    o.opOutcome != Permitted implies
      (no o.opCreatedNote and o.opReturnedClinicalContent = BFalse)
}
assert FR_006_ByteEquivalentDenial { FR_006_ByteEquivalentDenial }
check FR_006_ByteEquivalentDenial for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 / FR-019 / FR-020 (record-read response shape)
pred FR_007_19_20_RecordShape {
  all o: Operation |
    (o.opKind = RecordLookup and o.opOutcome = Permitted) implies
      (o.opReturnedClinicalContent = BTrue and no o.opCreatedNote)
}
assert FR_007_19_20_RecordShape { FR_007_19_20_RecordShape }
check FR_007_19_20_RecordShape for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 (out-of-scope clinical fields don't leak via notes)
pred FR_008_PatientSummaryScope {
  // Notes carry note content, not patient summary fields; this is enforced by sig shape.
  all n: ClinicalNote | one n.notePatient and one n.noteAuthor
}
assert FR_008_PatientSummaryScope { FR_008_PatientSummaryScope }
check FR_008_PatientSummaryScope for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 (no note created on failed validation/denial)
pred FR_009_NoteValidation {
  all o: Operation |
    some o.opCreatedNote implies
      (o.opKind = AddNote and o.opOutcome = Permitted)
}
assert FR_009_NoteValidation { FR_009_NoteValidation }
check FR_009_NoteValidation for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 (author snapshot fields are accurate at write time)
pred FR_010_NoteAuthorSnapshot {
  all n: ClinicalNote |
    n.noteAuthorRoleSnap = n.noteAuthor.role and
    n.noteAuthorRoleSnap in ClinicalRoles
}
assert FR_010_NoteAuthorSnapshot { FR_010_NoteAuthorSnapshot }
check FR_010_NoteAuthorSnapshot for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 (notes append-only)
pred FR_011_NotesAppendOnly {
  no n: ClinicalNote | n.noteModified = BTrue
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 (one audit entry per operation)
pred FR_012_OneAuditPerOp {
  all o: Operation | one ae: AuditEntry | ae.aeFor = o
}
assert FR_012_OneAuditPerOp { FR_012_OneAuditPerOp }
check FR_012_OneAuditPerOp for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 (audit entries carry all required fields, faithfully)
pred FR_013_AuditFieldsMatch {
  all ae: AuditEntry |
    ae.aeUserSnap = ae.aeFor.opCaller and
    ae.aeRoleSnap = ae.aeFor.opCaller.role and
    ae.aeKind = ae.aeFor.opKind and
    ae.aeOutcome = ae.aeFor.opOutcome and
    ae.aeBasis = ae.aeFor.opBasis and
    ae.aeNoteId = ae.aeFor.opCreatedNote
}
assert FR_013_AuditFieldsMatch { FR_013_AuditFieldsMatch }
check FR_013_AuditFieldsMatch for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 (audit immutable)
pred FR_014_AuditImmutable {
  no ae: AuditEntry | ae.aeModified = BTrue
}
assert FR_014_AuditImmutable { FR_014_AuditImmutable }
check FR_014_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 (2-second SLA: no orphan operation without audit)
pred FR_015_AuditOrRollback {
  all o: Operation | some ae: AuditEntry | ae.aeFor = o
}
assert FR_015_AuditOrRollback { FR_015_AuditOrRollback }
check FR_015_AuditOrRollback for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 (7-year retention: no deletion code path)
pred FR_016_AuditRetention {
  // Modelled as immutability: no audit entry is ever marked as modified/deleted.
  no ae: AuditEntry | ae.aeModified = BTrue
}
assert FR_016_AuditRetention { FR_016_AuditRetention }
check FR_016_AuditRetention for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 (audit-search endpoint is administrator-only)
pred FR_017_AdminOnlyAuditSearch {
  all o: Operation |
    (o.opKind = AuditSearch and o.opOutcome = Permitted) implies
      o.opCaller.role = HospitalAdministrator
}
assert FR_017_AdminOnlyAuditSearch { FR_017_AdminOnlyAuditSearch }
check FR_017_AdminOnlyAuditSearch for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 (administrator response contains no clinical content)
pred FR_018_NoClinicalLeakToAdmin {
  all o: Operation |
    o.opCaller.role = HospitalAdministrator implies
      o.opReturnedClinicalContent = BFalse
}
assert FR_018_NoClinicalLeakToAdmin { FR_018_NoClinicalLeakToAdmin }
check FR_018_NoClinicalLeakToAdmin for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_BadAttribution { some ae: AuditEntry | ae.aeUserSnap != ae.aeFor.opCaller }
