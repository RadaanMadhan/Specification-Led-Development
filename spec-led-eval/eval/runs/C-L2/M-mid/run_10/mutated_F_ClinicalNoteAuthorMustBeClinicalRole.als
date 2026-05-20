// === feature_model.als — Alloy model for Hospital Clinical Record Access (C-L2) ===
// Feature branch: 012-hospital-clinical-records
// Sources: spec.md FRs 001-020, data-model.md, contracts/http-api.md

// ═══════════════════════════════════════════════════════════════════════════════
// §1  ROLE AND OPERATION SIGS
// ═══════════════════════════════════════════════════════════════════════════════

abstract sig Role {}
one sig Doctor        extends Role {}
one sig Nurse         extends Role {}
one sig Pharmacist    extends Role {}
one sig ClinicalAdmin extends Role {}
one sig HospitalAdministrator extends Role {}

abstract sig OperationKind {}
one sig RecordLookup extends OperationKind {}  // POST /records/lookup
one sig AddNote      extends OperationKind {}  // POST /records/notes
one sig ListAudit    extends OperationKind {}  // POST /audit/search

// ═══════════════════════════════════════════════════════════════════════════════
// §2  PERMISSION MATRIX (contracts/http-api.md authorisation tables)
// ═══════════════════════════════════════════════════════════════════════════════

one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// PATTERN: LeastPrivilege / PermissionCompleteness
// ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-004, FR-005, FR-017
fact F_PermissionMatrix {
  // Exact set of allowed (Role, OperationKind) cells — closed-world
  PermMatrix.Allowed =
    (Doctor         -> RecordLookup) +
    (Nurse          -> RecordLookup) +
    (Pharmacist     -> RecordLookup) +
    (ClinicalAdmin  -> RecordLookup) +
    (Doctor         -> AddNote)      +
    (Nurse          -> AddNote)      +
    (Pharmacist     -> AddNote)      +
    (ClinicalAdmin  -> AddNote)      +
    (HospitalAdministrator -> ListAudit)
}

// ═══════════════════════════════════════════════════════════════════════════════
// §3  ACCESS OUTCOMES AND AUTHORISATION BASES
// ═══════════════════════════════════════════════════════════════════════════════

abstract sig Outcome {}
one sig Permitted        extends Outcome {}
one sig Denied           extends Outcome {}
one sig NotFoundOrDenied extends Outcome {}

abstract sig AuthBasis {}
one sig CareTeamMember    extends AuthBasis {}
one sig NotCareTeamMember extends AuthBasis {}
one sig PatientNotFound   extends AuthBasis {}
one sig AdministratorRole extends AuthBasis {}

abstract sig AuditAccessType {}
one sig AuditRead      extends AuditAccessType {}
one sig AuditAddNote   extends AuditAccessType {}
one sig AuditListAudit extends AuditAccessType {}

// ═══════════════════════════════════════════════════════════════════════════════
// §4  DOMAIN SIGS
// ═══════════════════════════════════════════════════════════════════════════════

sig User {
  role: one Role
}

sig Patient {}

// Active care-team membership rows (only active rows gate access per FR-004)
sig CareTeamMembership {
  ctClinician: one User,
  ctPatient:   one Patient
}

// Append-only clinical note (FR-011)
sig ClinicalNote {
  notePatient: one Patient,
  noteAuthor:  one User
}

// Immutable audit entry (FR-014)
sig AuditEntry {
  aeAccessor:  one User,
  aePatient:   one Patient,
  aeKind:      one AuditAccessType,
  aeOutcome:   one Outcome,
  aeBasis:     one AuthBasis,
  aeNoteRef:   lone ClinicalNote   // non-null iff add_note + permitted (FR-013)
}

// Represents one authenticated access attempt that passed the auth boundary
sig Operation {
  opCaller:   one User,
  opKind:     one OperationKind,
  opPatient:  one Patient,
  opOutcome:  one Outcome,
  opBasis:    one AuthBasis,
  opAudit:    one AuditEntry,      // exactly one audit entry per operation (FR-012)
  opNote:     lone ClinicalNote    // produced only for permitted AddNote (FR-010)
}

// ═══════════════════════════════════════════════════════════════════════════════
// §5  NON-EMPTY UNIVERSE
// ═══════════════════════════════════════════════════════════════════════════════

fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
  some Operation
}

// ═══════════════════════════════════════════════════════════════════════════════
// §6  STRUCTURAL FACTS
// ═══════════════════════════════════════════════════════════════════════════════

// Each Operation owns a DISTINCT AuditEntry; every AuditEntry is owned by exactly one Operation.
// ANCHOR: spec.md FR-012; data-model.md audit_entries append-only
fact F_AuditOneToOneWithOperation {
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
  all ae: AuditEntry | one op: Operation | op.opAudit = ae
}

// Audit entries accurately mirror the operation's caller, patient, outcome and basis.
// ANCHOR: spec.md FR-013; data-model.md AuditEntry fields
fact F_AuditFieldsMirrorOperation {
  all op: Operation | {
    op.opAudit.aeAccessor = op.opCaller
    op.opAudit.aePatient  = op.opPatient
    op.opAudit.aeOutcome  = op.opOutcome
    op.opAudit.aeBasis    = op.opBasis
  }
}

// AuditEntry access-type tag matches the operation kind.
// ANCHOR: spec.md FR-013; data-model.md AccessType enum
fact F_AuditAccessTypeMatchesKind {
  all op: Operation | {
    op.opKind = RecordLookup implies op.opAudit.aeKind = AuditRead
    op.opKind = AddNote      implies op.opAudit.aeKind = AuditAddNote
    op.opKind = ListAudit    implies op.opAudit.aeKind = AuditListAudit
  }
}

// noteRef in audit entry iff add_note + permitted; null otherwise.
// ANCHOR: spec.md FR-013; data-model.md AuditEntry CHECK constraint on note_id
fact F_NoteRefAuditConstraint {
  all ae: AuditEntry | {
    (ae.aeKind = AuditAddNote and ae.aeOutcome = Permitted)  implies one  ae.aeNoteRef
    (ae.aeKind = AuditAddNote and ae.aeOutcome != Permitted) implies no   ae.aeNoteRef
    ae.aeKind != AuditAddNote                                implies no   ae.aeNoteRef
  }
}

// opNote produced iff kind=AddNote AND outcome=Permitted; null otherwise.
// ANCHOR: spec.md FR-010; data-model.md ClinicalNote
fact F_NoteProducedOnlyOnPermittedAddNote {
  all op: Operation | {
    (op.opKind = AddNote and op.opOutcome = Permitted)  implies one  op.opNote
    (op.opKind = AddNote and op.opOutcome != Permitted) implies no   op.opNote
    op.opKind != AddNote                                implies no   op.opNote
  }
}

// The note referenced in the audit entry is exactly the note produced by the operation.
// ANCHOR: spec.md FR-010, FR-013
fact F_AuditNoteRefMatchesProducedNote {
  all op: Operation | op.opAudit.aeNoteRef = op.opNote
}

// Each ClinicalNote is produced by exactly one permitted AddNote operation.
// (Structural encoding of append-only: notes are created once, never deleted.)
// ANCHOR: spec.md FR-011, SC-007; data-model.md ClinicalNote append-only enforcement
fact F_AppendOnlyNotes {
  all note: ClinicalNote | one op: Operation |
    op.opKind = AddNote and op.opOutcome = Permitted and op.opNote = note
}

// Notes carry the caller's identity as author, and the correct patient.
// ANCHOR: spec.md FR-010; data-model.md ClinicalNote fields
fact F_NoteAuthorAndPatientFromOperation {
  all op: Operation | some op.opNote implies {
    op.opNote.noteAuthor  = op.opCaller
    op.opNote.notePatient = op.opPatient
  }
}

// Note authors must be clinical roles (not HospitalAdministrator).
// ANCHOR: spec.md FR-005, FR-010; data-model.md ClinicalNote author_role CHECK
fact F_ClinicalNoteAuthorMustBeClinicalRole { /* MUTATED — body cleared by validator */ }

// Every operation's caller must hold a role that the permission matrix allows for that kind.
// ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-004, FR-005, FR-017
fact F_RoleOperationPermission {
  all op: Operation |
    op.opCaller.role -> op.opKind in PermMatrix.Allowed
}

// A permitted clinical operation requires an active care-team membership.
// ANCHOR: spec.md FR-004; data-model.md CareTeamMembership; contracts/http-api.md FR-004
fact F_CareTeamGatingForClinicalOps {
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and op.opOutcome = Permitted) implies
    (some m: CareTeamMembership | m.ctClinician = op.opCaller and m.ctPatient = op.opPatient)
}

// Authorisation basis is consistent with outcome and kind.
// ANCHOR: spec.md FR-013; data-model.md AuthorisationBasis enum
fact F_AuthBasisConsistency {
  all op: Operation | {
    // Permitted clinical → care_team_member basis
    (op.opKind in (RecordLookup + AddNote) and op.opOutcome = Permitted) implies
      op.opBasis = CareTeamMember
    // Denied clinical → not_care_team_member
    (op.opKind in (RecordLookup + AddNote) and op.opOutcome = Denied) implies
      op.opBasis = NotCareTeamMember
    // NotFoundOrDenied → patient_not_found
    op.opOutcome = NotFoundOrDenied implies op.opBasis = PatientNotFound
    // Permitted admin list-audit → administrator_role
    (op.opKind = ListAudit and op.opOutcome = Permitted) implies
      op.opBasis = AdministratorRole
  }
}

// Denied and not-found responses are structurally indistinguishable (byte-equivalent envelope).
// Modelled as: the information leakage path through opNote is absent on all non-permitted ops.
// ANCHOR: spec.md FR-006, SC-003; contracts/http-api.md byte-equivalent not-found response
fact F_DeniedResponseLeaksNoContent {
  all op: Operation |
    op.opOutcome != Permitted implies no op.opNote
}

// ═══════════════════════════════════════════════════════════════════════════════
// §7  PATTERN PREDICATES AND ASSERTIONS
// ═══════════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; spec.md FR-004, FR-005, FR-017
pred LeastPrivilege {
  // HospitalAdministrator never performs clinical operations
  all op: Operation |
    op.opCaller.role = HospitalAdministrator implies
    op.opKind !in (RecordLookup + AddNote)
  // Clinical roles never perform list-audit operations
  all op: Operation |
    op.opCaller.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin) implies
    op.opKind != ListAudit
  // Confirm at least one operation exists to avoid vacuity
  some Operation
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables
pred PermissionCompleteness {
  // Every (Role, OperationKind) pair is either explicitly allowed or implicitly denied.
  // The allowed set is exactly the matrix; every cell has a verdict.
  PermMatrix.Allowed =
    (Doctor + Nurse + Pharmacist + ClinicalAdmin) -> (RecordLookup + AddNote) +
    HospitalAdministrator -> ListAudit
  some Operation
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012, SC-001, SC-002; data-model.md AuditEntry
pred AuditCompleteness {
  // Every operation has exactly one corresponding audit entry
  all op: Operation | one ae: AuditEntry | op.opAudit = ae
  // Every audit entry corresponds to exactly one operation
  all ae: AuditEntry | one op: Operation | op.opAudit = ae
  some Operation
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly (clinical notes)  ANCHOR: spec.md FR-011, SC-007; data-model.md ClinicalNote append-only
pred AppendOnly {
  // Every note is produced by exactly one permitted AddNote operation
  all note: ClinicalNote | one op: Operation |
    op.opKind = AddNote and op.opOutcome = Permitted and op.opNote = note
  // No note is produced by a non-AddNote operation
  all op: Operation | op.opKind != AddNote implies no op.opNote
  some ClinicalNote
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md AuditEntry snapshot fields
pred AttributionCorrectness {
  // Every audit entry's accessor matches the operation's caller
  all op: Operation | op.opAudit.aeAccessor = op.opCaller
  // Every audit entry's patient matches the operation's patient
  all op: Operation | op.opAudit.aePatient = op.opPatient
  // Every audit entry's outcome matches the operation's outcome
  all op: Operation | op.opAudit.aeOutcome = op.opOutcome
  some Operation
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  // Every permitted clinical operation has a care-team membership linking caller to patient
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and op.opOutcome = Permitted) implies
    (some m: CareTeamMembership | m.ctClinician = op.opCaller and m.ctPatient = op.opPatient)
  some op: Operation | op.opKind = RecordLookup and op.opOutcome = Permitted
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006, SC-003; contracts/http-api.md byte-equivalent response
pred NoInformationLeakage {
  // Non-permitted operations produce no clinical note (denied and not-found look identical)
  all op: Operation | op.opOutcome != Permitted implies no op.opNote
  // Non-permitted operations produce no noteRef in their audit entry
  all op: Operation | op.opOutcome != Permitted implies no op.opAudit.aeNoteRef
  some Operation
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// ═══════════════════════════════════════════════════════════════════════════════
// §8  FEATURE-SPECIFIC PREDICATES AND ASSERTIONS
// ═══════════════════════════════════════════════════════════════════════════════

// FEATURE-SPECIFIC  ANCHOR: FR-001; contracts/http-api.md authentication boundary
pred FR_001_AuthRequired {
  // Every operation has a caller that is a valid User (all Operations are post-auth)
  all op: Operation | some op.opCaller
  // No ClinicalNote exists without a corresponding permitted AddNote operation by a valid user
  all note: ClinicalNote | some op: Operation |
    op.opNote = note and op.opKind = AddNote and op.opOutcome = Permitted and some op.opCaller
  some Operation
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002; data-model.md UserRole enum
pred FR_002_OneRolePerUser {
  // Every user has exactly one role from the five-value catalogue
  all u: User | one u.role
  // The role must be one of the defined singletons (type-enforced, but assert coverage)
  all u: User | u.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin + HospitalAdministrator)
  some User
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004; data-model.md CareTeamMembership; contracts/http-api.md FR-004
pred FR_004_CareTeamGating {
  // Permitted record-read requires care-team membership
  all op: Operation |
    (op.opKind = RecordLookup and op.opOutcome = Permitted) implies
    (some m: CareTeamMembership | m.ctClinician = op.opCaller and m.ctPatient = op.opPatient)
  // Permitted add-note requires care-team membership
  all op: Operation |
    (op.opKind = AddNote and op.opOutcome = Permitted) implies
    (some m: CareTeamMembership | m.ctClinician = op.opCaller and m.ctPatient = op.opPatient)
  some op: Operation | op.opKind = RecordLookup and op.opOutcome = Permitted
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005, FR-018; spec.md administrator content-blindness
pred FR_005_AdminContentBlindness {
  // HospitalAdministrator never performs RecordLookup or AddNote
  all op: Operation |
    op.opCaller.role = HospitalAdministrator implies
    op.opKind !in (RecordLookup + AddNote)
  // No ClinicalNote is produced by an operation whose caller is HospitalAdministrator
  all op: Operation |
    op.opCaller.role = HospitalAdministrator implies no op.opNote
  // ListAudit operations produce no ClinicalNote (admin response carries no clinical content)
  all op: Operation | op.opKind = ListAudit implies no op.opNote
  some op: Operation | op.opKind = ListAudit
}
assert FR_005_AdminContentBlindness { FR_005_AdminContentBlindness }
check FR_005_AdminContentBlindness for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-011; data-model.md ClinicalNote author_role CHECK
pred FR_010_NoteAuthorIsClinicalRole {
  // All note authors hold a clinical role
  all note: ClinicalNote |
    note.noteAuthor.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
  // No note authored by a HospitalAdministrator
  no note: ClinicalNote | note.noteAuthor.role = HospitalAdministrator
  some ClinicalNote
}
assert FR_010_NoteAuthorIsClinicalRole { FR_010_NoteAuthorIsClinicalRole }
check FR_010_NoteAuthorIsClinicalRole for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011, SC-007; data-model.md ClinicalNote append-only enforcement
pred FR_011_NotesAppendOnly {
  // Every ClinicalNote is produced by exactly one operation
  all note: ClinicalNote | one op: Operation | op.opNote = note
  // That operation must be a permitted AddNote
  all note: ClinicalNote | all op: Operation |
    op.opNote = note implies (op.opKind = AddNote and op.opOutcome = Permitted)
  some ClinicalNote
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012, SC-001, SC-002; data-model.md always-on audit
pred FR_012_AlwaysOnAudit {
  // Every operation produces exactly one audit entry
  all op: Operation | one op.opAudit
  // Every audit entry is linked to exactly one operation
  all ae: AuditEntry | one op: Operation | op.opAudit = ae
  // No ClinicalNote exists without a corresponding audit entry
  all note: ClinicalNote | some ae: AuditEntry |
    ae.aeKind = AuditAddNote and ae.aeOutcome = Permitted and ae.aeNoteRef = note
  some Operation
}
assert FR_012_AlwaysOnAudit { FR_012_AlwaysOnAudit }
check FR_012_AlwaysOnAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013; data-model.md AuditEntry note_id CHECK constraint
pred FR_013_NoteIdInAuditOnlyForPermittedAddNote {
  // noteRef present iff add_note + permitted
  all ae: AuditEntry |
    (some ae.aeNoteRef) iff (ae.aeKind = AuditAddNote and ae.aeOutcome = Permitted)
  some AuditEntry
}
assert FR_013_NoteIdInAuditOnlyForPermittedAddNote { FR_013_NoteIdInAuditOnlyForPermittedAddNote }
check FR_013_NoteIdInAuditOnlyForPermittedAddNote for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014, FR-016, SC-008; data-model.md AuditEntry append-only enforcement
pred FR_014_AuditEntriesImmutable {
  // Every audit entry is linked to exactly one operation (no orphan or duplicate entries)
  all ae: AuditEntry | one op: Operation | op.opAudit = ae
  // No two operations share the same audit entry
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
  some AuditEntry
}
assert FR_014_AuditEntriesImmutable { FR_014_AuditEntriesImmutable }
check FR_014_AuditEntriesImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017; contracts/http-api.md POST /audit/search authorisation
pred FR_017_ListAuditAdminOnly {
  // Only HospitalAdministrator may perform permitted ListAudit operations
  all op: Operation |
    (op.opKind = ListAudit and op.opOutcome = Permitted) implies
    op.opCaller.role = HospitalAdministrator
  // Clinical roles never perform ListAudit (role-level gate, regardless of outcome)
  all op: Operation |
    op.opCaller.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin) implies
    op.opKind != ListAudit
  some op: Operation | op.opKind = ListAudit
}
assert FR_017_ListAuditAdminOnly { FR_017_ListAuditAdminOnly }
check FR_017_ListAuditAdminOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009; spec.md validation before mutation; contracts/http-api.md 400 validation_error
pred FR_009_ValidationBeforeMutation {
  // A note can only exist if a permitted AddNote operation produced it
  all note: ClinicalNote | some op: Operation |
    op.opNote = note and op.opOutcome = Permitted
  // No operation with a denied outcome produces a note
  all op: Operation | op.opOutcome != Permitted implies no op.opNote
  some ClinicalNote
}
assert FR_009_ValidationBeforeMutation { FR_009_ValidationBeforeMutation }
check FR_009_ValidationBeforeMutation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013; data-model.md AuditEntry attribution fields snapshot
pred FR_013_AttributionCorrectness {
  // Accessor in audit matches the actual caller of the operation
  all op: Operation | op.opAudit.aeAccessor = op.opCaller
  // Patient in audit matches the patient referenced in the operation
  all op: Operation | op.opAudit.aePatient = op.opPatient
  // Outcome in audit matches the operation's outcome
  all op: Operation | op.opAudit.aeOutcome = op.opOutcome
  // Basis in audit matches the operation's basis
  all op: Operation | op.opAudit.aeBasis = op.opBasis
  some Operation
}
assert FR_013_AttributionCorrectness { FR_013_AttributionCorrectness }
check FR_013_AttributionCorrectness for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AdminAuthorViolation { some note: ClinicalNote | note.noteAuthor.role = HospitalAdministrator }
