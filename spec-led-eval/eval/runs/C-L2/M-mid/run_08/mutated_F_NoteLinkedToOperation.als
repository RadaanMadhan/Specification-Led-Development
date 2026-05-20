// === feature_model.als — Alloy 6 model for Hospital Clinical Record Access ===
// Feature folder : C-L2  (branch 012-hospital-clinical-records)
// Sources        : spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────────────────────────────────
// Roles
// ─────────────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator
  extends Role {}

// ─────────────────────────────────────────────────────────────────────────────
// Operation kinds  (one per endpoint)
// ─────────────────────────────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig RecordsLookup, AddNote, AuditSearch extends OperationKind {}

// ─────────────────────────────────────────────────────────────────────────────
// Permission matrix — singleton field (Rule 7)
// ─────────────────────────────────────────────────────────────────────────────
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─────────────────────────────────────────────────────────────────────────────
// Dynamic sigs from data-model.md
// ─────────────────────────────────────────────────────────────────────────────
sig User    { userRole: one Role }
sig Patient {}

abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

sig CareTeamMembership {
  ctClinician : one User,
  ctPatient   : one Patient,
  ctStatus    : one MembershipStatus
}

abstract sig AccessType {}
one sig ReadAccess, AddNoteAccess, ListAuditAccess extends AccessType {}

abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

abstract sig AuthBasis {}
one sig CareTeamMemberBasis, NotCareTeamMemberBasis,
        PatientNotFoundBasis, AdministratorRoleBasis extends AuthBasis {}

// ClinicalNote — append-only (FR-011)
sig ClinicalNote {
  notePatient    : one Patient,
  noteAuthor     : one User,
  noteAuthorRole : one Role   // snapshot at creation time
}

// AuditEntry — immutable, append-only (FR-014)
sig AuditEntry {
  aeUser       : one User,
  aeUserRole   : one Role,         // snapshot at access time  (FR-013)
  aePatient    : one Patient,
  aeAccessType : one AccessType,
  aeOutcome    : one AccessOutcome,
  aeBasis      : one AuthBasis,
  aeNoteRef    : lone ClinicalNote // set iff AddNoteAccess + Permitted (FR-013)
}

// Operation — one authenticated, post-validation access attempt
// (unauthenticated / validation-failing requests are outside this model;
//  they produce no audit entry and no state change per FR-001 / FR-009)
sig Operation {
  opUser    : one User,
  opPatient : one Patient,
  opKind    : one OperationKind,
  opOutcome : one AccessOutcome,
  opAudit   : one AuditEntry,     // exactly one audit entry per operation (FR-012)
  opNote    : lone ClinicalNote   // only for AddNote + Permitted (FR-010)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NonEmptyUniverse — at least one atom of every dynamic sig
// ─────────────────────────────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
  some Operation
}

// ─────────────────────────────────────────────────────────────────────────────
// F_PermissionMatrix — closed-world permission matrix
// contracts/http-api.md authorisation tables; spec.md FR-004, FR-005, FR-017
// ─────────────────────────────────────────────────────────────────────────────
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor              -> RecordsLookup) +
    (Doctor              -> AddNote)       +
    (Nurse               -> RecordsLookup) +
    (Nurse               -> AddNote)       +
    (Pharmacist          -> RecordsLookup) +
    (Pharmacist          -> AddNote)       +
    (ClinicalAdmin       -> RecordsLookup) +
    (ClinicalAdmin       -> AddNote)       +
    (HospitalAdministrator -> AuditSearch)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_LeastPrivilegeEnforced — permitted ops must appear in the matrix
// spec.md FR-004, FR-005; contracts/http-api.md authorisation sections
// ─────────────────────────────────────────────────────────────────────────────
fact F_LeastPrivilegeEnforced {
  all op: Operation |
    op.opOutcome = Permitted implies
    (op.opUser.userRole -> op.opKind) in PermMatrix.Allowed
}

// ─────────────────────────────────────────────────────────────────────────────
// F_CareTeamGating — clinical ops permitted iff active care-team membership
// spec.md FR-004; data-model.md CareTeamMembership
// ─────────────────────────────────────────────────────────────────────────────
fact F_CareTeamGating {
  all op: Operation |
    (op.opKind = RecordsLookup or op.opKind = AddNote) implies
    (
      op.opOutcome = Permitted iff
      (
        op.opUser.userRole != HospitalAdministrator and
        (some ctm: CareTeamMembership |
           ctm.ctClinician = op.opUser  and
           ctm.ctPatient   = op.opPatient and
           ctm.ctStatus    = Active)
      )
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AdminAuditGating — AuditSearch permitted iff HospitalAdministrator
// spec.md FR-017; contracts/http-api.md POST /audit/search
// ─────────────────────────────────────────────────────────────────────────────
fact F_AdminAuditGating {
  all op: Operation |
    op.opKind = AuditSearch implies
    (op.opOutcome = Permitted iff op.opUser.userRole = HospitalAdministrator)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NoteOnlyOnPermittedAddNote — note created iff AddNote + Permitted
// spec.md FR-010; data-model.md ClinicalNote
// ─────────────────────────────────────────────────────────────────────────────
fact F_NoteOnlyOnPermittedAddNote {
  all op: Operation |
    (some op.opNote) iff (op.opKind = AddNote and op.opOutcome = Permitted)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NoteAuthorIsClinical — note author_role is never HospitalAdministrator
// data-model.md CHECK(author_role IN ('doctor','nurse','pharmacist','clinical_admin'))
// spec.md FR-005
// ─────────────────────────────────────────────────────────────────────────────
fact F_NoteAuthorIsClinical {
  all n: ClinicalNote | n.noteAuthorRole != HospitalAdministrator
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NoteAuthorRoleSnapshot — snapshotted role matches actual user role
// data-model.md ClinicalNote.author_role (snapshot field)
// ─────────────────────────────────────────────────────────────────────────────
fact F_NoteAuthorRoleSnapshot {
  all n: ClinicalNote | n.noteAuthorRole = n.noteAuthor.userRole
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NoteLinkedToOperation — each note belongs to exactly one creating operation
// spec.md FR-011 (append-only); data-model.md append-only enforcement
// ─────────────────────────────────────────────────────────────────────────────
fact F_NoteLinkedToOperation { /* MUTATED — body cleared by validator */ }

// ─────────────────────────────────────────────────────────────────────────────
// F_NotePatientMatchesOperation — note's patient equals the operation's patient
// data-model.md ClinicalNote.patient_id
// ─────────────────────────────────────────────────────────────────────────────
fact F_NotePatientMatchesOperation {
  all op: Operation |
    (some op.opNote) implies
    (op.opNote.notePatient = op.opPatient and
     op.opNote.noteAuthor  = op.opUser)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditExactlyOnePerOperation — each operation owns a distinct audit entry
// spec.md FR-012; data-model.md AuditEntry
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditExactlyOnePerOperation {
  // no two operations share an audit entry
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditEntriesAppendOnly — every audit entry belongs to exactly one operation
// spec.md FR-014; data-model.md AuditEntry append-only enforcement
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditEntriesAppendOnly {
  all ae: AuditEntry |
    one op: Operation | op.opAudit = ae
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditAttributionCorrect — snapshotted role matches user's actual role
// spec.md FR-013; data-model.md AuditEntry.user_role (snapshot)
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditAttributionCorrect {
  all ae: AuditEntry |
    ae.aeUserRole = ae.aeUser.userRole
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditFieldsMatchOperation — audit entry fields mirror the operation
// spec.md FR-013; contracts/http-api.md behaviour sections
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditFieldsMatchOperation {
  all op: Operation | let ae = op.opAudit | {
    ae.aeUser    = op.opUser
    ae.aePatient = op.opPatient
    ae.aeOutcome = op.opOutcome
    // access type mirrors operation kind
    (op.opKind = RecordsLookup  implies ae.aeAccessType = ReadAccess)
    (op.opKind = AddNote         implies ae.aeAccessType = AddNoteAccess)
    (op.opKind = AuditSearch     implies ae.aeAccessType = ListAuditAccess)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditNoteIdConstraint — note_id set iff AddNoteAccess + Permitted
// data-model.md structural CHECK; spec.md FR-013
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditNoteIdConstraint {
  all ae: AuditEntry |
    (ae.aeAccessType = AddNoteAccess and ae.aeOutcome = Permitted)
    iff
    (one ae.aeNoteRef)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditNoteRefMatchesOpNote — audit's note reference equals the created note
// spec.md FR-013 note_id field; data-model.md AuditEntry.note_id
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditNoteRefMatchesOpNote {
  all op: Operation |
    (some op.opNote) implies op.opAudit.aeNoteRef = op.opNote
}

// ─────────────────────────────────────────────────────────────────────────────
// F_CareTeamClinicianRoleOnly — only clinical-role users appear as clinicians
// data-model.md CareTeamMembership; spec.md FR-004
// ─────────────────────────────────────────────────────────────────────────────
fact F_CareTeamClinicianRoleOnly {
  all ctm: CareTeamMembership |
    ctm.ctClinician.userRole != HospitalAdministrator
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuthBasisConsistency — authorisation basis is consistent with outcome
// spec.md FR-013 authorisation_basis field; contracts/http-api.md behaviour
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuthBasisConsistency {
  all ae: AuditEntry | {
    ae.aeBasis = CareTeamMemberBasis     implies ae.aeOutcome = Permitted
    ae.aeBasis = AdministratorRoleBasis  implies ae.aeOutcome = Permitted
    ae.aeBasis = NotCareTeamMemberBasis  implies ae.aeOutcome = Denied
    ae.aeBasis = PatientNotFoundBasis    implies ae.aeOutcome = NotFoundOrDenied
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ─── PREDICATES AND ASSERTIONS ───────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-004, FR-005, FR-017
pred LeastPrivilege {
  some Operation  // non-vacuous: at least one operation must exist
  all op: Operation |
    op.opOutcome = Permitted implies
    (op.opUser.userRole -> op.opKind) in PermMatrix.Allowed
  // No HospitalAdministrator can have a permitted RecordsLookup or AddNote
  no op: Operation |
    op.opUser.userRole = HospitalAdministrator and
    (op.opKind = RecordsLookup or op.opKind = AddNote) and
    op.opOutcome = Permitted
  // No clinical role can have a permitted AuditSearch
  no op: Operation |
    op.opUser.userRole != HospitalAdministrator and
    op.opKind = AuditSearch and
    op.opOutcome = Permitted
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables; spec.md FR-004, FR-005
pred PermissionCompleteness {
  // Every (Role x OperationKind) pair is either in Allowed or its complement.
  // Concretely: the matrix covers all five roles and all three operations.
  all r: Role, ok: OperationKind |
    (r -> ok) in PermMatrix.Allowed or (r -> ok) not in PermMatrix.Allowed
  // The matrix is non-empty (not vacuously empty)
  some PermMatrix.Allowed
  // All roles appear somewhere in the matrix
  all r: Role | some ok: OperationKind | (r -> ok) in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-004, FR-005, FR-017; contracts/http-api.md
pred PermissionGrounding {
  // Every allowed (Role, OperationKind) cell corresponds to an FR-traced permission.
  // Modelled as: the allowed set is exactly the nine cells grounded in the spec,
  // not a subset and not a superset.
  PermMatrix.Allowed =
    (Doctor              -> RecordsLookup) +
    (Doctor              -> AddNote)       +
    (Nurse               -> RecordsLookup) +
    (Nurse               -> AddNote)       +
    (Pharmacist          -> RecordsLookup) +
    (Pharmacist          -> AddNote)       +
    (ClinicalAdmin       -> RecordsLookup) +
    (ClinicalAdmin       -> AddNote)       +
    (HospitalAdministrator -> AuditSearch)
  some PermMatrix.Allowed
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
  // Every Operation has a resolved User (no anonymous operations in the model).
  // The model expresses this structurally: opUser is `one User`, so every
  // operation is tied to an authenticated user.
  some Operation
  all op: Operation | one op.opUser
  // Every audit entry is attributed to a real user
  all ae: AuditEntry | one ae.aeUser
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012, SC-001, SC-002; data-model.md AuditEntry
pred AuditCompleteness {
  // Every operation in the model has exactly one audit entry.
  some Operation
  all op: Operation | one op.opAudit
  // No audit entry exists without a corresponding operation.
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
  // No two distinct operations share an audit entry.
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly (clinical notes)  ANCHOR: spec.md FR-011, SC-007; data-model.md append-only enforcement
pred AppendOnly {
  // Each clinical note is produced by exactly one operation and never mutated.
  some ClinicalNote
  all n: ClinicalNote | (one op: Operation | op.opNote = n)
  // Each audit entry is produced by exactly one operation and never mutated.
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md AuditEntry snapshot fields
pred AttributionCorrectness {
  some AuditEntry
  all ae: AuditEntry | ae.aeUserRole = ae.aeUser.userRole
  // The audit entry's user matches the operation's user
  all op: Operation | op.opAudit.aeUser = op.opUser
  // The audit entry's patient matches the operation's patient
  all op: Operation | op.opAudit.aePatient = op.opPatient
  // The audit entry's outcome matches the operation's outcome
  all op: Operation | op.opAudit.aeOutcome = op.opOutcome
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  // For every clinical operation permitted, there is an active care-team membership.
  some op: Operation |
    (op.opKind = RecordsLookup or op.opKind = AddNote) and
    op.opOutcome = Permitted
  all op: Operation |
    (op.opKind = RecordsLookup or op.opKind = AddNote) and
    op.opOutcome = Permitted implies
    (
      op.opUser.userRole != HospitalAdministrator and
      (some ctm: CareTeamMembership |
         ctm.ctClinician = op.opUser and
         ctm.ctPatient   = op.opPatient and
         ctm.ctStatus    = Active)
    )
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006, SC-003; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  // Non-permitted operations never produce clinical notes.
  some Operation
  no op: Operation | op.opOutcome != Permitted and (some op.opNote)
  // Audit entries for denied operations carry no note reference.
  all ae: AuditEntry |
    ae.aeOutcome != Permitted implies (no ae.aeNoteRef)
  // Specifically: Denied and NotFoundOrDenied operations look structurally
  // identical in terms of note/content absence.
  all op: Operation |
    (op.opOutcome = Denied or op.opOutcome = NotFoundOrDenied) implies
    (no op.opNote)
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// FEATURE-SPECIFIC  ANCHOR: FR-001 — authentication required; no unauthenticated ops in model
pred FR_001_AuthRequired {
  // Every operation is tied to a User with a resolved role.
  some Operation
  all op: Operation |
    one op.opUser and one op.opUser.userRole
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 — care-team gating for clinical access
pred FR_004_CareTeamGating {
  // A clinical-role user gets Permitted only with an active care-team row.
  some op: Operation | op.opKind = RecordsLookup
  all op: Operation |
    (op.opKind = RecordsLookup or op.opKind = AddNote) and
    op.opOutcome = Permitted implies
    (
      op.opUser.userRole != HospitalAdministrator and
      (some ctm: CareTeamMembership |
         ctm.ctClinician = op.opUser and
         ctm.ctPatient   = op.opPatient and
         ctm.ctStatus    = Active)
    )
  // A clinical user without active care-team membership is not Permitted.
  all op: Operation |
    (op.opKind = RecordsLookup or op.opKind = AddNote) and
    op.opUser.userRole != HospitalAdministrator and
    (no ctm: CareTeamMembership |
       ctm.ctClinician = op.opUser and
       ctm.ctPatient   = op.opPatient and
       ctm.ctStatus    = Active)
    implies op.opOutcome != Permitted
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 — administrator cannot access clinical content
pred FR_005_AdminCannotAccessClinicalContent {
  // HospitalAdministrator never has a permitted RecordsLookup or AddNote.
  no op: Operation |
    op.opUser.userRole = HospitalAdministrator and
    (op.opKind = RecordsLookup or op.opKind = AddNote) and
    op.opOutcome = Permitted
  // HospitalAdministrator never produces a clinical note.
  no op: Operation |
    op.opUser.userRole = HospitalAdministrator and
    (some op.opNote)
  some User  // non-vacuous
}
assert FR_005_AdminCannotAccessClinicalContent { FR_005_AdminCannotAccessClinicalContent }
check FR_005_AdminCannotAccessClinicalContent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005, FR-017 — administrator-only audit search
pred FR_017_AdminOnlyAuditSearch {
  // AuditSearch is permitted only for HospitalAdministrator.
  some op: Operation | op.opKind = AuditSearch
  all op: Operation |
    op.opKind = AuditSearch and op.opOutcome = Permitted implies
    op.opUser.userRole = HospitalAdministrator
  // Clinical-role users never have a permitted AuditSearch.
  no op: Operation |
    op.opUser.userRole != HospitalAdministrator and
    op.opKind = AuditSearch and
    op.opOutcome = Permitted
}
assert FR_017_AdminOnlyAuditSearch { FR_017_AdminOnlyAuditSearch }
check FR_017_AdminOnlyAuditSearch for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-011 — notes are append-only; no edit/delete
pred FR_011_NotesAppendOnly {
  // Each note is associated with exactly one AddNote+Permitted operation.
  some ClinicalNote
  all n: ClinicalNote |
    (one op: Operation |
       op.opNote = n and
       op.opKind = AddNote and
       op.opOutcome = Permitted)
  // No note is associated with more than one operation.
  all disj op1, op2: Operation |
    (some op1.opNote and some op2.opNote) implies op1.opNote != op2.opNote
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012, SC-001, SC-002 — always-on audit for every access attempt
pred FR_012_AlwaysOnAudit {
  // Every operation in the model produces exactly one audit entry.
  some Operation
  all op: Operation | one op.opAudit
  // Every audit entry is produced by exactly one operation.
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
}
assert FR_012_AlwaysOnAudit { FR_012_AlwaysOnAudit }
check FR_012_AlwaysOnAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 — audit entry note_id set iff add_note + permitted
pred FR_013_AuditNoteIdConstraint {
  some AuditEntry
  // note_id (aeNoteRef) is present iff AddNoteAccess + Permitted.
  all ae: AuditEntry |
    (ae.aeAccessType = AddNoteAccess and ae.aeOutcome = Permitted)
    iff (one ae.aeNoteRef)
  // For read and list_audit operations, note ref is always absent.
  all ae: AuditEntry |
    (ae.aeAccessType = ReadAccess or ae.aeAccessType = ListAuditAccess) implies
    (no ae.aeNoteRef)
}
assert FR_013_AuditNoteIdConstraint { FR_013_AuditNoteIdConstraint }
check FR_013_AuditNoteIdConstraint for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014, SC-008 — audit entries are immutable / append-only
pred FR_014_AuditImmutable {
  // Every audit entry is owned by exactly one operation, never shared or mutated.
  some AuditEntry
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
  // No two operations share an audit entry.
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
}
assert FR_014_AuditImmutable { FR_014_AuditImmutable }
check FR_014_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009, FR-010 — note author is a clinical role (not administrator)
pred FR_010_NoteAuthorIsClinical {
  some ClinicalNote
  all n: ClinicalNote | n.noteAuthorRole != HospitalAdministrator
  all n: ClinicalNote |
    n.noteAuthorRole = Doctor or
    n.noteAuthorRole = Nurse or
    n.noteAuthorRole = Pharmacist or
    n.noteAuthorRole = ClinicalAdmin
}
assert FR_010_NoteAuthorIsClinical { FR_010_NoteAuthorIsClinical }
check FR_010_NoteAuthorIsClinical for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009, FR-015 — note only created when outcome is Permitted
pred FR_009_NoteOnlyOnPermittedAddNote {
  // Proof: an AddNote operation with non-Permitted outcome produces no note.
  some op: Operation | op.opKind = AddNote and op.opOutcome = Permitted
  all op: Operation |
    (some op.opNote) iff (op.opKind = AddNote and op.opOutcome = Permitted)
}
assert FR_009_NoteOnlyOnPermittedAddNote { FR_009_NoteOnlyOnPermittedAddNote }
check FR_009_NoteOnlyOnPermittedAddNote for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 — HospitalAdministrator has no care-team membership
pred FR_004_AdminNotOnCareTeam {
  // HospitalAdministrator never appears as a clinician in any care-team row.
  all ctm: CareTeamMembership |
    ctm.ctClinician.userRole != HospitalAdministrator
  some CareTeamMembership  // non-vacuous
}
assert FR_004_AdminNotOnCareTeam { FR_004_AdminNotOnCareTeam }
check FR_004_AdminNotOnCareTeam for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006, SC-003 — denied and not-found responses are structurally indistinguishable
pred FR_006_DeniedLooksLikeNotFound {
  // Both Denied and NotFoundOrDenied operations produce no note and no note ref in audit.
  some op: Operation | op.opOutcome = Denied
  all op: Operation |
    (op.opOutcome = Denied or op.opOutcome = NotFoundOrDenied) implies
    (no op.opNote)
  all ae: AuditEntry |
    (ae.aeOutcome = Denied or ae.aeOutcome = NotFoundOrDenied) implies
    (no ae.aeNoteRef)
}
assert FR_006_DeniedLooksLikeNotFound { FR_006_DeniedLooksLikeNotFound }
check FR_006_DeniedLooksLikeNotFound for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 — audit attribution snapshot correctness
pred FR_013_AuditAttributionSnapshot {
  some AuditEntry
  all ae: AuditEntry | ae.aeUserRole = ae.aeUser.userRole
  all op: Operation | {
    op.opAudit.aeUser    = op.opUser
    op.opAudit.aePatient = op.opPatient
    op.opAudit.aeOutcome = op.opOutcome
  }
}
assert FR_013_AuditAttributionSnapshot { FR_013_AuditAttributionSnapshot }
check FR_013_AuditAttributionSnapshot for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AppendOnlyViolation { some disj op1, op2: Operation | op1.opNote = op2.opNote and some op1.opNote }
