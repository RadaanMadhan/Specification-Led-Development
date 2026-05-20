// === feature_model.als — Hospital Clinical Record Access (012-hospital-clinical-records) ===

// =====================================================================
// ROLE / ENDPOINT / OUTCOME ENUMS
// =====================================================================

abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator extends Role {}

abstract sig OperationKind {}
one sig PostRecordsLookup, PostRecordsNotes, PostAuditSearch extends OperationKind {}

abstract sig Outcome {}
one sig Permitted, Denied, NotFoundOrDenied extends Outcome {}

abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

// =====================================================================
// ENTITIES (mirroring data-model.md)
// =====================================================================

sig User { role: one Role }
sig Patient {}

sig CareTeamMembership {
  clinician: one User,
  member_patient: one Patient,
  ctm_status: one MembershipStatus
}

sig ClinicalNote {
  note_patient: one Patient,
  author: one User,
  authorRoleSnapshot: one Role
}

sig AuditEntry {
  ae_user: one User,
  ae_userRole: one Role,
  ae_patient: one Patient,
  ae_kind: one OperationKind,
  ae_outcome: one Outcome,
  ae_note: lone ClinicalNote
}

sig Operation {
  caller: one User,
  callerRoleSnapshot: one Role,
  target: one Patient,
  kind: one OperationKind,
  outcome: one Outcome,
  audit: one AuditEntry,
  createdNote: lone ClinicalNote
}

// Permission matrix (contracts/http-api.md authorisation tables).
one sig PermMatrix { Allowed: set Role -> OperationKind }

// =====================================================================
// NON-EMPTY UNIVERSE  (every dynamic sig has at least one atom)
// =====================================================================

fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
  some Operation
}

// =====================================================================
// PERMISSION MATRIX
// Closed-world: only these (Role, OperationKind) cells are allowed.
//   - Doctor / Nurse / Pharmacist / ClinicalAdmin  ->  Lookup, Notes
//   - HospitalAdministrator                        ->  AuditSearch
// (anchor: contracts/http-api.md; spec FR-004, FR-005, FR-017)
// =====================================================================

fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Doctor                -> PostRecordsLookup)
    + (Doctor                -> PostRecordsNotes)
    + (Nurse                 -> PostRecordsLookup)
    + (Nurse                 -> PostRecordsNotes)
    + (Pharmacist            -> PostRecordsLookup)
    + (Pharmacist            -> PostRecordsNotes)
    + (ClinicalAdmin         -> PostRecordsLookup)
    + (ClinicalAdmin         -> PostRecordsNotes)
    + (HospitalAdministrator -> PostAuditSearch)
}

// =====================================================================
// AUTH / ATTRIBUTION FACTS
// =====================================================================

// FR-001 / FR-002 — caller's snapshotted role equals current user role.
fact F_CallerRoleSnapshotMatches {
  all op: Operation | op.callerRoleSnapshot = op.caller.role
}

// FR-012 / FR-014 — one audit entry per operation (bijection).
fact F_OneAuditPerOperation {
  all disj o1, o2: Operation | o1.audit != o2.audit
  all ae: AuditEntry | (some op: Operation | op.audit = ae)
}

// FR-013 — audit entry mirrors the operation it records (attribution).
fact F_AuditMirrorsOperation {
  all op: Operation |
    op.audit.ae_user      = op.caller and
    op.audit.ae_userRole  = op.callerRoleSnapshot and
    op.audit.ae_patient   = op.target and
    op.audit.ae_kind      = op.kind and
    op.audit.ae_outcome   = op.outcome
}

// =====================================================================
// AUTHORISATION FACTS
// =====================================================================

// FR-004 / FR-005 / FR-017 — permitted operations live inside the matrix.
fact F_LeastPrivilegeRule { /* MUTATED — body cleared by validator */ }

// FR-004 — care-team gating for clinical endpoints.
fact F_CareTeamGating {
  all op: Operation |
    (op.outcome = Permitted and op.kind in (PostRecordsLookup + PostRecordsNotes)) implies
      (op.callerRoleSnapshot in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
       (some ctm: CareTeamMembership |
          ctm.clinician       = op.caller and
          ctm.member_patient  = op.target and
          ctm.ctm_status      = Active))
}

// =====================================================================
// NOTE FACTS (FR-009, FR-010, FR-011)
// =====================================================================

// FR-006 / FR-009 / FR-010 — a created note exists exactly when the
// operation was a permitted add_note.
fact F_NoteOnlyOnPermittedAddNote {
  all op: Operation |
    (some op.createdNote) iff (op.kind = PostRecordsNotes and op.outcome = Permitted)
}

// FR-010 — the created note's snapshotted author/patient/role match the op.
fact F_NoteFieldsMatchOperation {
  all op: Operation |
    some op.createdNote implies
      (op.createdNote.author             = op.caller and
       op.createdNote.note_patient       = op.target and
       op.createdNote.authorRoleSnapshot = op.callerRoleSnapshot)
}

// FR-005 / FR-009 — a note's author role is one of the four clinical roles.
// (data-model.md: CHECK(author_role IN ('doctor','nurse','pharmacist','clinical_admin')))
fact F_NoteAuthorRoleClinical {
  all n: ClinicalNote | n.authorRoleSnapshot in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}

// FR-011 — append-only: each note is created by exactly one operation.
fact F_NoteCreatedByOneOperation {
  all n: ClinicalNote | (one op: Operation | op.createdNote = n)
}

// FR-013 — audit entry's note pointer matches the operation's created note.
// (This + F_NoteOnlyOnPermittedAddNote + F_AuditMirrorsOperation derives
//  the data-model.md note_id CHECK constraint.)
fact F_AuditNoteIsOperationNote {
  all op: Operation | op.audit.ae_note = op.createdNote
}

// =====================================================================
// ASSERTIONS — STRUCTURAL CORRECTNESS PATTERNS
// =====================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md auth tables; spec.md FR-004, FR-005, FR-017
pred LeastPrivilege {
  some Operation
  all op: Operation |
    op.outcome = Permitted implies
      (op.callerRoleSnapshot -> op.kind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
  // Every cell either is in Allowed or is in its complement — total coverage.
  all r: Role, k: OperationKind |
    (r -> k) in PermMatrix.Allowed or (r -> k) not in PermMatrix.Allowed
  // And the matrix contains at least the documented clinician grants:
  Doctor    -> PostRecordsLookup in PermMatrix.Allowed
  Nurse     -> PostRecordsLookup in PermMatrix.Allowed
  HospitalAdministrator -> PostAuditSearch in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-005, FR-017
pred PermissionGrounding {
  // No silent grants: every "allow" must be one of the documented cells.
  // Documented forbidden cells must remain forbidden.
  HospitalAdministrator -> PostRecordsLookup not in PermMatrix.Allowed
  HospitalAdministrator -> PostRecordsNotes  not in PermMatrix.Allowed
  Doctor        -> PostAuditSearch not in PermMatrix.Allowed
  Nurse         -> PostAuditSearch not in PermMatrix.Allowed
  Pharmacist    -> PostAuditSearch not in PermMatrix.Allowed
  ClinicalAdmin -> PostAuditSearch not in PermMatrix.Allowed
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012; data-model.md audit_entries
pred AuditCompleteness {
  some Operation
  // bijection Operation <-> AuditEntry
  all op: Operation | one op.audit
  all disj o1, o2: Operation | o1.audit != o2.audit
  all ae: AuditEntry | (some op: Operation | op.audit = ae)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011, FR-014; data-model.md no UPDATE/DELETE
pred AppendOnly {
  some ClinicalNote
  // Every note is created by exactly one operation; no orphan notes,
  // no two operations creating the same note.
  all n: ClinicalNote | (one op: Operation | op.createdNote = n)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md audit-entry snapshot fields
pred AttributionCorrectness {
  some Operation
  all op: Operation |
    op.audit.ae_user     = op.caller and
    op.audit.ae_userRole = op.callerRoleSnapshot and
    op.audit.ae_patient  = op.target and
    op.audit.ae_kind     = op.kind and
    op.audit.ae_outcome  = op.outcome
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md care_team_memberships
pred OwnershipBasedAccess {
  some Operation
  all op: Operation |
    (op.outcome = Permitted and op.kind in (PostRecordsLookup + PostRecordsNotes)) implies
      (some ctm: CareTeamMembership |
         ctm.clinician      = op.caller and
         ctm.member_patient = op.target and
         ctm.ctm_status     = Active)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006; contracts/http-api.md byte-equivalent 404
pred NoInformationLeakage {
  // Denied/not-found clinical operations produce no clinical artefact
  // observable to the caller (no created note pinned to the operation).
  some Operation
  all op: Operation |
    (op.kind in (PostRecordsLookup + PostRecordsNotes) and op.outcome != Permitted) implies
      no op.createdNote
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// =====================================================================
// ASSERTIONS — FR-NNN COVERAGE
// =====================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 (auth required; role from identity context, not request)
pred FR_001_AuthRequired {
  some Operation
  // Every operation has an authenticated user whose role is taken from
  // the host identity context (snapshot equals current user.role).
  all op: Operation | op.callerRoleSnapshot = op.caller.role
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 (five-role catalogue, exclusive)
pred FR_002_FiveRoleCatalogue {
  Role = Doctor + Nurse + Pharmacist + ClinicalAdmin + HospitalAdministrator
  all u: User | u.role in Role
}
assert FR_002_FiveRoleCatalogue { FR_002_FiveRoleCatalogue }
check FR_002_FiveRoleCatalogue for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 (clinical endpoint = care-team membership required)
pred FR_004_CareTeamGating {
  some Operation
  all op: Operation |
    (op.kind in (PostRecordsLookup + PostRecordsNotes) and op.outcome = Permitted) implies
      (op.callerRoleSnapshot in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
       (some ctm: CareTeamMembership |
          ctm.clinician      = op.caller and
          ctm.member_patient = op.target and
          ctm.ctm_status     = Active))
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 (administrator never gets clinical content)
pred FR_005_AdminAuditOnly {
  all op: Operation |
    op.callerRoleSnapshot = HospitalAdministrator implies
      (op.kind = PostAuditSearch or op.outcome != Permitted)
}
assert FR_005_AdminAuditOnly { FR_005_AdminAuditOnly }
check FR_005_AdminAuditOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 (denied response leaks no clinical state)
pred FR_006_DenialNoLeakage {
  all op: Operation |
    (op.kind in (PostRecordsLookup + PostRecordsNotes) and op.outcome != Permitted) implies
      no op.createdNote
}
assert FR_006_DenialNoLeakage { FR_006_DenialNoLeakage }
check FR_006_DenialNoLeakage for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 (note author must be one of the four clinical roles)
pred FR_009_NoteAuthorIsClinical {
  some ClinicalNote
  all n: ClinicalNote |
    n.authorRoleSnapshot in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}
assert FR_009_NoteAuthorIsClinical { FR_009_NoteAuthorIsClinical }
check FR_009_NoteAuthorIsClinical for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 (note fields match the authenticated caller/target)
pred FR_010_NoteAuthorMatchesOperation {
  all op: Operation |
    some op.createdNote implies
      (op.createdNote.author             = op.caller and
       op.createdNote.note_patient       = op.target and
       op.createdNote.authorRoleSnapshot = op.callerRoleSnapshot)
}
assert FR_010_NoteAuthorMatchesOperation { FR_010_NoteAuthorMatchesOperation }
check FR_010_NoteAuthorMatchesOperation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 (notes append-only — exactly one creating op per note)
pred FR_011_NotesAppendOnly {
  some ClinicalNote
  all n: ClinicalNote | (one op: Operation | op.createdNote = n)
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 (one audit entry per operation, no orphans)
pred FR_012_OneAuditPerOperation {
  some Operation
  all op: Operation | one op.audit
  all disj o1, o2: Operation | o1.audit != o2.audit
  all ae: AuditEntry | (some op: Operation | op.audit = ae)
}
assert FR_012_OneAuditPerOperation { FR_012_OneAuditPerOperation }
check FR_012_OneAuditPerOperation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 (audit note_id present iff add_note + permitted)
pred FR_013_AuditNoteFieldGating {
  all ae: AuditEntry |
    (some ae.ae_note) iff (ae.ae_kind = PostRecordsNotes and ae.ae_outcome = Permitted)
}
assert FR_013_AuditNoteFieldGating { FR_013_AuditNoteFieldGating }
check FR_013_AuditNoteFieldGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 (audit entries immutable — bijection to operations)
pred FR_014_AuditImmutable {
  some AuditEntry
  all ae: AuditEntry | (one op: Operation | op.audit = ae)
}
assert FR_014_AuditImmutable { FR_014_AuditImmutable }
check FR_014_AuditImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 (audit-search endpoint accessible only to administrators)
pred FR_017_AdminOnlyAuditEndpoint {
  all op: Operation |
    (op.kind = PostAuditSearch and op.outcome = Permitted) implies
      op.callerRoleSnapshot = HospitalAdministrator
}
assert FR_017_AdminOnlyAuditEndpoint { FR_017_AdminOnlyAuditEndpoint }
check FR_017_AdminOnlyAuditEndpoint for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 (admin response carries opaque note_id only, never note content)
pred FR_018_AdminAuditCarriesOnlyOpaquePointer {
  // The administrator response is built from AuditEntry. AuditEntry's link
  // to a note is the opaque ae_note reference (data-model.md note_id),
  // present only on a permitted add_note row. No body field exists on
  // AuditEntry. Structural consequence: every ae with ae_note is keyed to
  // a *successful* note-creation event — never an attempted/denied access.
  all ae: AuditEntry |
    some ae.ae_note implies
      (ae.ae_kind = PostRecordsNotes and ae.ae_outcome = Permitted)
}
assert FR_018_AdminAuditCarriesOnlyOpaquePointer { FR_018_AdminAuditCarriesOnlyOpaquePointer }
check FR_018_AdminAuditCarriesOnlyOpaquePointer for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_DoctorPermittedAudit { some op: Operation | op.callerRoleSnapshot = Doctor and op.kind = PostAuditSearch and op.outcome = Permitted }
