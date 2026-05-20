// === feature_model.als — Alloy 6 model for Hospital Clinical Record Access (C-L2) ===
// Feature branch: 012-hospital-clinical-records
// Artefacts: spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────
// ROLE HIERARCHY
// ─────────────────────────────────────────────
abstract sig Role {}
abstract sig ClinicalRole extends Role {}
one sig Doctor      extends ClinicalRole {}
one sig Nurse       extends ClinicalRole {}
one sig Pharmacist  extends ClinicalRole {}
one sig ClinicalAdmin extends ClinicalRole {}
one sig HospitalAdministrator extends Role {}

// ─────────────────────────────────────────────
// OPERATION KINDS  (one per endpoint)
// ─────────────────────────────────────────────
abstract sig OperationKind {}
one sig RecordsLookup extends OperationKind {}   // POST /records/lookup
one sig RecordsNotes  extends OperationKind {}   // POST /records/notes
one sig AuditSearch   extends OperationKind {}   // POST /audit/search

// ─────────────────────────────────────────────
// PERMISSION MATRIX  (singleton field — FR-004, FR-005, FR-017)
// ─────────────────────────────────────────────
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─────────────────────────────────────────────
// ACCESS OUTCOME / ACCESS TYPE  (mirrors SQL enums)
// ─────────────────────────────────────────────
abstract sig AccessOutcome {}
one sig Permitted        extends AccessOutcome {}
one sig Denied           extends AccessOutcome {}
one sig NotFoundOrDenied extends AccessOutcome {}

abstract sig AccessType {}
one sig ReadAccess     extends AccessType {}   // "read"
one sig AddNoteAccess  extends AccessType {}   // "add_note"
one sig ListAuditAccess extends AccessType {}  // "list_audit"

// ─────────────────────────────────────────────
// DOMAIN SIGS  (dynamic — every one appears in F_NonEmptyUniverse)
// ─────────────────────────────────────────────
sig User {
  userRole: one Role
}

sig Patient {}

// Active care-team memberships only (ended rows cannot authorise access).
sig ActiveMembership {
  memberClinician : one User,
  memberPatient   : one Patient
}

// Append-only clinical notes (FR-011).
sig ClinicalNote {
  notePatient    : one Patient,
  noteAuthor     : one User,
  // Author role is snapshotted at write time (FR-010) and MUST be a clinical role (data-model CHECK).
  noteAuthorRole : one ClinicalRole
}

// Immutable audit entries (FR-014).
sig AuditEntry {
  entryUser       : one User,
  entryUserRole   : one Role,    // snapshot (FR-013)
  entryPatient    : one Patient,
  entryAccessType : one AccessType,
  entryOutcome    : one AccessOutcome,
  // Populated only when access_type = add_note AND outcome = permitted (FR-013 structural CHECK).
  entryNoteRef    : lone ClinicalNote
}

// An Operation models one authenticated, validation-passing access attempt that
// reaches the service layer.  Unauthenticated / validation-failed requests are
// NOT Operations (they do not produce audit entries — FR-001, FR-009).
sig Operation {
  opCaller  : one User,
  opKind    : one OperationKind,
  opPatient : one Patient,
  opOutcome : one AccessOutcome,
  // Every Operation that reaches the service layer produces EXACTLY ONE audit entry (FR-012).
  opAudit   : one AuditEntry
}

// ─────────────────────────────────────────────
// F_NonEmptyUniverse  — prevents vacuous all-quantifiers under `check ... for 5`
// ─────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some Patient
  some ActiveMembership
  some ClinicalNote
  some AuditEntry
  some Operation
}

// ─────────────────────────────────────────────
// F_PermissionMatrix  — PATTERN: LeastPrivilege / PermissionCompleteness
// contracts/http-api.md authorisation tables; spec.md FR-004, FR-005, FR-017
// ─────────────────────────────────────────────
fact F_PermissionMatrix {
  // Closed-world: enumerate every allowed (Role × OperationKind) cell.
  PermMatrix.Allowed =
      (Doctor         -> RecordsLookup)
    + (Doctor         -> RecordsNotes)
    + (Nurse          -> RecordsLookup)
    + (Nurse          -> RecordsNotes)
    + (Pharmacist     -> RecordsLookup)
    + (Pharmacist     -> RecordsNotes)
    + (ClinicalAdmin  -> RecordsLookup)
    + (ClinicalAdmin  -> RecordsNotes)
    + (HospitalAdministrator -> AuditSearch)
}

// ─────────────────────────────────────────────
// F_OperationsRespectPermissionMatrix
// Only operations that the permission matrix allows can have outcome = Permitted.
// contracts/http-api.md; spec.md FR-004, FR-005
// ─────────────────────────────────────────────
fact F_OperationsRespectPermissionMatrix {
  all op: Operation |
    op.opOutcome = Permitted implies
      (op.opCaller.userRole -> op.opKind) in PermMatrix.Allowed
}

// ─────────────────────────────────────────────
// F_CareTeamGating
// A clinical-role Operation can succeed only when the caller holds an active
// care-team membership for the target patient (FR-004).
// ─────────────────────────────────────────────
fact F_CareTeamGating { /* MUTATED — body cleared by validator */ }

// ─────────────────────────────────────────────
// F_AuditEntryBijection
// Every Operation owns EXACTLY ONE AuditEntry and that entry is not shared
// across Operations (one-to-one link, FR-012).
// ─────────────────────────────────────────────
fact F_AuditEntryBijection {
  // opAudit is already `one AuditEntry` per Operation.
  // Injectivity: no two Operations share the same AuditEntry.
  all disj o1, o2: Operation | o1.opAudit != o2.opAudit
  // Every AuditEntry in the universe belongs to some Operation.
  all ae: AuditEntry | some op: Operation | op.opAudit = ae
}

// ─────────────────────────────────────────────
// F_AttributionCorrectness
// Audit entry's user and role snapshots match the actual caller of the
// Operation they record (FR-013; data-model.md audit-entry fields).
// ─────────────────────────────────────────────
fact F_AttributionCorrectness {
  all op: Operation | let ae = op.opAudit | {
    ae.entryUser     = op.opCaller
    ae.entryUserRole = op.opCaller.userRole
    ae.entryPatient  = op.opPatient
  }
}

// ─────────────────────────────────────────────
// F_AuditAccessTypeMatchesOpKind
// Audit access_type mirrors the operation kind (FR-013).
// ─────────────────────────────────────────────
fact F_AuditAccessTypeMatchesOpKind {
  all op: Operation | let ae = op.opAudit | {
    op.opKind = RecordsLookup  implies ae.entryAccessType = ReadAccess
    op.opKind = RecordsNotes   implies ae.entryAccessType = AddNoteAccess
    op.opKind = AuditSearch    implies ae.entryAccessType = ListAuditAccess
  }
}

// ─────────────────────────────────────────────
// F_AuditOutcomeMatchesOpOutcome
// Audit outcome is identical to Operation outcome (FR-013).
// ─────────────────────────────────────────────
fact F_AuditOutcomeMatchesOpOutcome {
  all op: Operation | op.opAudit.entryOutcome = op.opOutcome
}

// ─────────────────────────────────────────────
// F_NoteRefConstraint
// entryNoteRef is set IFF access_type = add_note AND outcome = permitted
// (data-model.md structural CHECK; FR-013).
// ─────────────────────────────────────────────
fact F_NoteRefConstraint {
  all ae: AuditEntry | {
    (ae.entryAccessType = AddNoteAccess and ae.entryOutcome = Permitted) implies
      (one ae.entryNoteRef)
    (ae.entryAccessType = AddNoteAccess and ae.entryOutcome != Permitted) implies
      (no ae.entryNoteRef)
    (ae.entryAccessType in (ReadAccess + ListAuditAccess)) implies
      (no ae.entryNoteRef)
  }
}

// ─────────────────────────────────────────────
// F_NoteAuthorIsClinicalRole
// ClinicalNote.noteAuthorRole is a ClinicalRole; and that role matches
// the author's actual role in the model (data-model.md author_role CHECK;
// FR-005 prevents HospitalAdministrator from being an author).
// ─────────────────────────────────────────────
fact F_NoteAuthorIsClinicalRole {
  all n: ClinicalNote | {
    // The snapshotted role is a ClinicalRole (enforced by the field type, but
    // also: the author's live role must be a ClinicalRole at authoring time).
    n.noteAuthor.userRole in ClinicalRole
    // Snapshot must equal the author's actual role (no misattribution on notes).
    n.noteAuthor.userRole = n.noteAuthorRole
  }
}

// ─────────────────────────────────────────────
// F_AppendOnlyClinicalNotes
// Each ClinicalNote is uniquely identified; no two notes share the same
// (author, patient, role) triple, modelling that notes can only be added
// (never mutated — if a note were mutated, it would appear as a different
// logical atom with the same key, which this fact rules out by structural
// identity) (FR-011; data-model.md append-only enforcement).
// ─────────────────────────────────────────────
fact F_AppendOnlyClinicalNotes {
  // No two distinct ClinicalNote atoms share (author, patient, authorRole).
  // This encodes uniqueness of the immutable key triple; mutation would create
  // a second atom with the same author/patient but different content fields —
  // ruled out by identity.
  all disj n1, n2: ClinicalNote |
    not (n1.noteAuthor = n2.noteAuthor
      and n1.notePatient = n2.notePatient
      and n1.noteAuthorRole = n2.noteAuthorRole)
}

// ─────────────────────────────────────────────
// F_AppendOnlyAuditEntries
// AuditEntry atoms are unique: no two entries may share the same
// (entryUser, entryPatient, entryAccessType) triple, encoding that an entry
// once written cannot be overwritten (FR-014; data-model.md append-only).
// ─────────────────────────────────────────────
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry |
    not (ae1.entryUser = ae2.entryUser
      and ae1.entryPatient = ae2.entryPatient
      and ae1.entryAccessType = ae2.entryAccessType
      and ae1.entryOutcome = ae2.entryOutcome)
}

// ─────────────────────────────────────────────
// F_AdminContentBlindness
// AuditSearch operations (admin endpoint) must NOT yield a ClinicalNote
// reference in their audit entry (FR-005, FR-018).
// ─────────────────────────────────────────────
fact F_AdminContentBlindness {
  all op: Operation |
    op.opKind = AuditSearch implies (no op.opAudit.entryNoteRef)
}

// ─────────────────────────────────────────────
// F_NoInformationLeakage
// Denied and NotFoundOrDenied operations for clinical endpoints must not
// carry a NoteRef (no clinical content leaks through the denial path —
// FR-006; contracts/http-api.md byte-equivalent unauthorised response).
// ─────────────────────────────────────────────
fact F_NoInformationLeakage {
  all op: Operation |
    (op.opOutcome in (Denied + NotFoundOrDenied)) implies (no op.opAudit.entryNoteRef)
}

// ─────────────────────────────────────────────
// F_AdminCannotAccessClinicalContent
// HospitalAdministrator callers are only allowed on AuditSearch (FR-005).
// If they attempt RecordsLookup or RecordsNotes, outcome must not be Permitted.
// ─────────────────────────────────────────────
fact F_AdminCannotAccessClinicalContent {
  all op: Operation |
    (op.opCaller.userRole = HospitalAdministrator
      and op.opKind in (RecordsLookup + RecordsNotes))
    implies op.opOutcome != Permitted
}

// ─────────────────────────────────────────────
// F_ClinicalRolesCannotListAudit
// Clinical-role callers cannot successfully use AuditSearch (FR-017).
// ─────────────────────────────────────────────
fact F_ClinicalRolesCannotListAudit {
  all op: Operation |
    (op.opCaller.userRole in ClinicalRole and op.opKind = AuditSearch)
    implies op.opOutcome != Permitted
}

// ─────────────────────────────────────────────
// F_OneRolePerUser
// Each User holds exactly one Role (data-model.md FR-002).
// (Structural: `userRole: one Role` already enforces this, but naming
// makes it mutation-testable.)
// ─────────────────────────────────────────────
fact F_OneRolePerUser {
  all u: User | one u.userRole
}

// ─────────────────────────────────────────────
// F_ActiveMembershipCliniciansOnly
// Only Users with a ClinicalRole can be members of a care team (FR-004).
// ─────────────────────────────────────────────
fact F_ActiveMembershipCliniciansOnly {
  all m: ActiveMembership | m.memberClinician.userRole in ClinicalRole
}

// ═════════════════════════════════════════════
// PREDICATES AND ASSERTIONS
// ═════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-004, FR-005, FR-017
pred LeastPrivilege {
  some Operation
  // HospitalAdministrator cannot reach Permitted on clinical endpoints.
  all op: Operation |
    (op.opCaller.userRole = HospitalAdministrator
      and op.opKind in (RecordsLookup + RecordsNotes))
    implies op.opOutcome != Permitted
  // ClinicalRole cannot reach Permitted on AuditSearch.
  all op: Operation |
    (op.opCaller.userRole in ClinicalRole and op.opKind = AuditSearch)
    implies op.opOutcome != Permitted
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables
pred PermissionCompleteness {
  // Every (Role × OperationKind) pair has a defined verdict: either it is
  // in the Allowed set, or it is implicitly denied.  The matrix is total.
  all r: Role, ok: OperationKind |
    (r -> ok) in PermMatrix.Allowed or (r -> ok) not in PermMatrix.Allowed
  // More usefully: the Allowed set is exactly the set we declared (no extra cells).
  some PermMatrix.Allowed
  #(PermMatrix.Allowed) = 9
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  some AuditEntry
  // Every AuditEntry in the system belongs to an Operation — there are no
  // "orphan" audit entries that could be written by an unauthenticated path
  // (since Operations require a `one User` caller, all entries are attributed).
  all ae: AuditEntry | some op: Operation | op.opAudit = ae
  // Additionally: every AuditEntry's entryUser resolves to a known User.
  all ae: AuditEntry | ae.entryUser in User
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: data-model.md UNIQUE constraints; spec.md FR-012, SC-001, SC-002
pred AuditCompleteness {
  some Operation
  // Every Operation produces exactly one audit entry.
  all op: Operation | one op.opAudit
  // Injectivity: distinct Operations produce distinct AuditEntries.
  all disj o1, o2: Operation | o1.opAudit != o2.opAudit
  // Coverage: every AuditEntry has a corresponding Operation.
  all ae: AuditEntry | (some op: Operation | op.opAudit = ae)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly (clinical notes)  ANCHOR: spec.md FR-011, SC-007; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  some ClinicalNote
  // No two distinct ClinicalNote atoms have the same immutable key triple —
  // encoding that notes are never overwritten.
  all disj n1, n2: ClinicalNote |
    not (n1.noteAuthor = n2.noteAuthor
      and n1.notePatient = n2.notePatient
      and n1.noteAuthorRole = n2.noteAuthorRole)
  // No two distinct AuditEntry atoms can represent a mutation of the same event.
  some AuditEntry
  all disj ae1, ae2: AuditEntry |
    not (ae1.entryUser = ae2.entryUser
      and ae1.entryPatient = ae2.entryPatient
      and ae1.entryAccessType = ae2.entryAccessType
      and ae1.entryOutcome = ae2.entryOutcome)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md audit-entry fields; spec.md FR-013
pred AttributionCorrectness {
  some Operation
  all op: Operation | let ae = op.opAudit | {
    ae.entryUser     = op.opCaller
    ae.entryUserRole = op.opCaller.userRole
    ae.entryPatient  = op.opPatient
  }
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  some Operation
  // A clinical operation is permitted only when the caller is on the care team.
  all op: Operation |
    (op.opKind in (RecordsLookup + RecordsNotes) and op.opOutcome = Permitted) implies
      (some m: ActiveMembership |
        m.memberClinician = op.opCaller and m.memberPatient = op.opPatient)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006, SC-003; contracts/http-api.md byte-equivalent response
pred NoInformationLeakage {
  some Operation
  // Denied responses carry no clinical reference (note ref is null on denied ops).
  all op: Operation |
    (op.opOutcome in (Denied + NotFoundOrDenied)) implies (no op.opAudit.entryNoteRef)
  // Admin endpoint operations carry no clinical note reference.
  all op: Operation |
    op.opKind = AuditSearch implies (no op.opAudit.entryNoteRef)
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001 — authentication boundary; no audit entry without resolved user
pred FR_001_AuthRequired {
  some AuditEntry
  // Every AuditEntry is associated with an Operation that has a resolved User caller.
  all ae: AuditEntry | (some op: Operation | op.opAudit = ae and op.opCaller in User)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 — exactly five roles; each User has exactly one
pred FR_002_OneRolePerUser {
  some User
  all u: User | one u.userRole
  // The role catalogue is exactly the five declared sigs.
  Role = ClinicalRole + HospitalAdministrator
  ClinicalRole = Doctor + Nurse + Pharmacist + ClinicalAdmin
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 — care-team gating; fail-closed; no break-glass
pred FR_004_CareTeamGating {
  some Operation
  all op: Operation |
    (op.opKind in (RecordsLookup + RecordsNotes) and op.opOutcome = Permitted) implies
      (some m: ActiveMembership |
        m.memberClinician = op.opCaller and m.memberPatient = op.opPatient)
  // Fail-closed: an admin attempting a clinical endpoint is never permitted.
  all op: Operation |
    (op.opCaller.userRole = HospitalAdministrator
      and op.opKind in (RecordsLookup + RecordsNotes))
    implies op.opOutcome != Permitted
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 — administrator cannot read clinical content
pred FR_005_AdminContentBlindness {
  some Operation
  // Admin operations on clinical endpoints are never Permitted.
  all op: Operation |
    (op.opCaller.userRole = HospitalAdministrator
      and op.opKind in (RecordsLookup + RecordsNotes))
    implies op.opOutcome != Permitted
  // Admin audit entries never reference a ClinicalNote.
  all op: Operation |
    op.opCaller.userRole = HospitalAdministrator implies (no op.opAudit.entryNoteRef)
}
assert FR_005_AdminContentBlindness { FR_005_AdminContentBlindness }
check FR_005_AdminContentBlindness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 / FR-010 — validation before note persisted; note body rules
pred FR_009_ValidationBeforeMutation {
  some ClinicalNote
  // Every persisted ClinicalNote is associated with at least one permitted
  // add-note Operation on its patient (no note exists without a Permitted write path).
  all n: ClinicalNote |
    some op: Operation |
      op.opKind = RecordsNotes
      and op.opOutcome = Permitted
      and op.opPatient = n.notePatient
      and op.opAudit.entryNoteRef = n
}
assert FR_009_ValidationBeforeMutation { FR_009_ValidationBeforeMutation }
check FR_009_ValidationBeforeMutation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 / FR-011 — notes are append-only; author role is clinical only
pred FR_011_NotesAppendOnly {
  some ClinicalNote
  // No ClinicalNote has a HospitalAdministrator as its author (schema CHECK).
  all n: ClinicalNote | n.noteAuthorRole in ClinicalRole
  // No two distinct notes share the same immutable identity triple.
  all disj n1, n2: ClinicalNote |
    not (n1.noteAuthor = n2.noteAuthor
      and n1.notePatient = n2.notePatient
      and n1.noteAuthorRole = n2.noteAuthorRole)
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 — always-on audit; no successful change without audit entry
pred FR_012_AuditAlwaysOn {
  some Operation
  // One-to-one: each Operation has exactly one AuditEntry; each AuditEntry has at most one Operation.
  all op: Operation | one op.opAudit
  all disj o1, o2: Operation | o1.opAudit != o2.opAudit
  all ae: AuditEntry | (some op: Operation | op.opAudit = ae)
}
assert FR_012_AuditAlwaysOn { FR_012_AuditAlwaysOn }
check FR_012_AuditAlwaysOn for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 — note_id present iff add_note + permitted
pred FR_013_NoteRefConstraint {
  some AuditEntry
  all ae: AuditEntry | {
    (ae.entryAccessType = AddNoteAccess and ae.entryOutcome = Permitted) implies
      (one ae.entryNoteRef)
    (ae.entryAccessType = AddNoteAccess and ae.entryOutcome != Permitted) implies
      (no ae.entryNoteRef)
    (ae.entryAccessType in (ReadAccess + ListAuditAccess)) implies
      (no ae.entryNoteRef)
  }
}
assert FR_013_NoteRefConstraint { FR_013_NoteRefConstraint }
check FR_013_NoteRefConstraint for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 / FR-016 — audit entries are immutable and retained
pred FR_014_AuditImmutability {
  some AuditEntry
  // No two AuditEntry atoms represent an overwrite of the same event record.
  all disj ae1, ae2: AuditEntry |
    not (ae1.entryUser = ae2.entryUser
      and ae1.entryPatient = ae2.entryPatient
      and ae1.entryAccessType = ae2.entryAccessType
      and ae1.entryOutcome = ae2.entryOutcome)
  // Every AuditEntry is owned by exactly one Operation (no orphan entries).
  all ae: AuditEntry | one op: Operation | op.opAudit = ae
}
assert FR_014_AuditImmutability { FR_014_AuditImmutability }
check FR_014_AuditImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 — AuditSearch is admin-only
pred FR_017_AuditSearchAdminOnly {
  some Operation
  all op: Operation |
    (op.opKind = AuditSearch and op.opOutcome = Permitted) implies
      op.opCaller.userRole = HospitalAdministrator
}
assert FR_017_AuditSearchAdminOnly { FR_017_AuditSearchAdminOnly }
check FR_017_AuditSearchAdminOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 — administrator response contains no clinical content fields
pred FR_018_AdminResponseNoClinicalContent {
  some Operation
  // Admins doing AuditSearch: their audit entries must have no note reference.
  all op: Operation |
    (op.opCaller.userRole = HospitalAdministrator and op.opKind = AuditSearch) implies
      (no op.opAudit.entryNoteRef)
  // Admins cannot reach Permitted on clinical endpoints at all.
  all op: Operation |
    op.opCaller.userRole = HospitalAdministrator implies
      op.opKind not in (RecordsLookup + RecordsNotes) or op.opOutcome != Permitted
}
assert FR_018_AdminResponseNoClinicalContent { FR_018_AdminResponseNoClinicalContent }
check FR_018_AdminResponseNoClinicalContent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 — ActiveMembership clinicians are always ClinicalRole users
pred FR_004_ActiveMembershipShape {
  some ActiveMembership
  all m: ActiveMembership | m.memberClinician.userRole in ClinicalRole
}
assert FR_004_ActiveMembershipShape { FR_004_ActiveMembershipShape }
check FR_004_ActiveMembershipShape for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_CareTeamGatingViolation { some op: Operation, u: User, p: Patient | op.opCaller = u and op.opPatient = p and op.opKind = RecordsLookup and op.opOutcome = Permitted and u.userRole = Doctor and (no m: ActiveMembership | m.memberClinician = u and m.memberPatient = p) }
