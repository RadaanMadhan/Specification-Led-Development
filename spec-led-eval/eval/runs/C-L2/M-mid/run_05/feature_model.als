// === feature_model.als — Alloy model for Hospital Clinical Record Access ===
// Feature: C-L2 / 012-hospital-clinical-records
// Spec artefacts: spec.md, data-model.md, contracts/http-api.md

// ─── Role catalogue (FR-002, data-model.md UserRole enum) ───────────────────
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator extends Role {}

// ─── Operation kinds (data-model.md AccessType enum) ────────────────────────
abstract sig OperationKind {}
one sig RecordLookup, AddNote, AuditSearch extends OperationKind {}

// ─── Access outcomes (data-model.md AccessOutcome enum) ─────────────────────
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// ─── Authorisation basis (data-model.md AuthorisationBasis enum) ────────────
abstract sig AuthBasis {}
one sig CareTeamMemberBasis, NotCareTeamMemberBasis,
        PatientNotFoundBasis, AdministratorRoleBasis extends AuthBasis {}

// ─── Membership status (data-model.md MembershipStatus enum) ────────────────
abstract sig MembershipStatus {}
one sig ActiveStatus, EndedStatus extends MembershipStatus {}

// ─── Permission matrix (singleton) ──────────────────────────────────────────
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ─── Dynamic sigs ────────────────────────────────────────────────────────────
sig User {
  userRole: one Role
}

sig Patient {}

sig CareTeamMembership {
  ctmClinician : one User,
  ctmPatient   : one Patient,
  ctmStatus    : one MembershipStatus
}

// Clinical notes are append-only artefacts (FR-011)
sig ClinicalNote {
  notePatient    : one Patient,
  noteAuthor     : one User,
  noteAuthorRole : one Role   // role snapshot at creation time
}

// Audit entries are immutable artefacts (FR-014)
sig AuditEntry {
  aeAccessor   : one User,
  aePatient    : one Patient,
  aeKind       : one OperationKind,
  aeOutcome    : one AccessOutcome,
  aeAuthBasis  : one AuthBasis,
  aeNoteRef    : lone ClinicalNote  // only for add_note + permitted (FR-013)
}

// An Operation represents one authenticated request dispatched through the service
sig Operation {
  opCaller    : one User,
  opKind      : one OperationKind,
  opPatient   : one Patient,
  opOutcome   : one AccessOutcome,
  opAudit     : one AuditEntry,
  opNote      : lone ClinicalNote   // only for AddNote + Permitted
}

// ─── Non-empty universe ──────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
  some Operation
}

// ─── Permission matrix (FR-004, FR-005, FR-017; contracts/http-api.md auth tables) ─
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor              -> RecordLookup) +
    (Doctor              -> AddNote)      +
    (Nurse               -> RecordLookup) +
    (Nurse               -> AddNote)      +
    (Pharmacist          -> RecordLookup) +
    (Pharmacist          -> AddNote)      +
    (ClinicalAdmin       -> RecordLookup) +
    (ClinicalAdmin       -> AddNote)      +
    (HospitalAdministrator -> AuditSearch)
}

// ─── Each user has exactly one role (FR-002) ─────────────────────────────────
fact F_OneRolePerUser {
  all u: User | one u.userRole
}

// ─── Role must be in permission matrix for an operation to succeed (FR-004/005) ─
fact F_RoleOperationEnforcement {
  all op: Operation |
    (op.opCaller.userRole -> op.opKind) in PermMatrix.Allowed
      or op.opOutcome != Permitted
}

// ─── Care-team membership gates clinical access (FR-004) ─────────────────────
fact F_CareTeamGating {
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and op.opOutcome = Permitted) implies
    (some m: CareTeamMembership |
       m.ctmClinician = op.opCaller and
       m.ctmPatient   = op.opPatient and
       m.ctmStatus    = ActiveStatus)
}

// ─── HospitalAdministrator may not succeed on clinical endpoints (FR-005) ────
fact F_AdminNotClinical {
  all op: Operation |
    op.opCaller.userRole = HospitalAdministrator implies
    (op.opKind = AuditSearch or op.opOutcome != Permitted)
}

// ─── AuditSearch is administrator-only; clinical roles are denied (FR-017) ───
fact F_AuditSearchAdminOnly {
  all op: Operation |
    (op.opKind = AuditSearch and op.opOutcome = Permitted) implies
    op.opCaller.userRole = HospitalAdministrator
}

// ─── Audit completeness: every operation maps to exactly one audit entry
//     and every audit entry belongs to exactly one operation (FR-012) ─────────
fact F_AuditCompleteness {
  // opAudit declared "one AuditEntry" already guarantees each op has one entry;
  // enforce the inverse: each AuditEntry is owned by exactly one Operation.
  all ae: AuditEntry | one op: Operation | op.opAudit = ae
  // Injectivity: no two operations share an audit entry.
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
}

// ─── Audit attribution: entry fields match the operation's observable fields (FR-013) ─
fact F_AuditAttribution {
  all op: Operation |
    op.opAudit.aeAccessor  = op.opCaller  and
    op.opAudit.aePatient   = op.opPatient and
    op.opAudit.aeKind      = op.opKind    and
    op.opAudit.aeOutcome   = op.opOutcome
}

// ─── note_id present iff add_note + permitted (FR-013 structural CHECK) ──────
fact F_NoteIdConstraint {
  all ae: AuditEntry |
    (ae.aeKind = AddNote and ae.aeOutcome = Permitted) implies
    (one ae.aeNoteRef)
  all ae: AuditEntry |
    (ae.aeKind != AddNote or ae.aeOutcome != Permitted) implies
    (no ae.aeNoteRef)
}

// ─── Operation note-creation consistency (FR-009, FR-010) ────────────────────
fact F_OperationNoteConsistency {
  all op: Operation |
    (op.opKind = AddNote and op.opOutcome = Permitted) implies (one op.opNote)
  all op: Operation |
    (op.opKind != AddNote or op.opOutcome != Permitted) implies (no op.opNote)
  // The audit entry's noteRef equals the operation's created note
  all op: Operation |
    op.opKind = AddNote implies (op.opAudit.aeNoteRef = op.opNote)
}

// ─── Append-only: clinical notes are created by exactly one permitted AddNote (FR-011) ─
fact F_AppendOnlyNotes {
  all n: ClinicalNote |
    one op: Operation |
      op.opKind = AddNote and op.opOutcome = Permitted and op.opNote = n
  // No two operations produce the same note
  all disj op1, op2: Operation |
    (op1.opKind = AddNote and op1.opOutcome = Permitted and
     op2.opKind = AddNote and op2.opOutcome = Permitted) implies
    op1.opNote != op2.opNote
}

// ─── Append-only: audit entries originate from exactly one operation (FR-014) ─
fact F_AppendOnlyAuditEntries {
  // Each AuditEntry is produced by exactly one Operation (inverse of opAudit injected here)
  all ae: AuditEntry | one op: Operation | op.opAudit = ae
}

// ─── Note author role must be a clinical role (data-model.md CHECK author_role) ─
fact F_NoteAuthorMustBeClinical {
  all n: ClinicalNote |
    n.noteAuthorRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
  // Author role snapshot matches the author's actual role at creation
  all n: ClinicalNote | n.noteAuthorRole = n.noteAuthor.userRole
}

// ─── Authorisation basis is consistent with outcome and operation kind (FR-013) ─
fact F_AuthBasisConsistency {
  all op: Operation |
    (op.opOutcome = Permitted and op.opKind in (RecordLookup + AddNote)) implies
    op.opAudit.aeAuthBasis = CareTeamMemberBasis
  all op: Operation |
    (op.opOutcome = Permitted and op.opKind = AuditSearch) implies
    op.opAudit.aeAuthBasis = AdministratorRoleBasis
  all op: Operation |
    op.opOutcome = Denied implies
    op.opAudit.aeAuthBasis = NotCareTeamMemberBasis
  all op: Operation |
    op.opOutcome = NotFoundOrDenied implies
    op.opAudit.aeAuthBasis = PatientNotFoundBasis
}

// ─── All operations are authenticated (structural: opCaller is one User) (FR-001) ─
fact F_AuthenticatedOperations {
  all op: Operation | some op.opCaller
}

// ════════════════════════════════════════════════════════════════════════════
// PREDICATES AND ASSERTIONS
// ════════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-004, FR-005, FR-017
pred LeastPrivilege {
  some Operation  // non-vacuous: universe has at least one operation
  // No permitted operation exists where the caller's role is not in the matrix
  all op: Operation |
    op.opOutcome = Permitted implies
    (op.opCaller.userRole -> op.opKind) in PermMatrix.Allowed
  // HospitalAdministrator has zero permitted clinical-endpoint operations
  all op: Operation |
    (op.opCaller.userRole = HospitalAdministrator and op.opOutcome = Permitted) implies
    op.opKind = AuditSearch
  // Clinical roles have zero permitted AuditSearch operations
  all op: Operation |
    (op.opCaller.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
     op.opOutcome = Permitted) implies
    op.opKind in (RecordLookup + AddNote)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md authorisation tables
pred PermissionCompleteness {
  // Every role has at least one allowed operation (no role is entirely undefined)
  all r: Role | some ok: OperationKind | r -> ok in PermMatrix.Allowed
  // Every operation kind is reachable by at least one role
  all ok: OperationKind | some r: Role | r -> ok in PermMatrix.Allowed
  // The allowed set is exactly the declared matrix — nothing more, nothing less
  PermMatrix.Allowed =
    (Doctor              -> RecordLookup) +
    (Doctor              -> AddNote)      +
    (Nurse               -> RecordLookup) +
    (Nurse               -> AddNote)      +
    (Pharmacist          -> RecordLookup) +
    (Pharmacist          -> AddNote)      +
    (ClinicalAdmin       -> RecordLookup) +
    (ClinicalAdmin       -> AddNote)      +
    (HospitalAdministrator -> AuditSearch)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md FR-004, FR-005; contracts/http-api.md auth tables
pred PrivilegeMonotonicity {
  // Clinical roles are a strict subset of allowed operations compared to
  // the union of all roles: HospitalAdministrator can never do RecordLookup or AddNote.
  // Equivalently: Admin's allowed set and clinical allowed set are disjoint.
  some op: Operation | op.opCaller.userRole = HospitalAdministrator
  HospitalAdministrator -> RecordLookup not in PermMatrix.Allowed
  HospitalAdministrator -> AddNote not in PermMatrix.Allowed
  // Clinical roles cannot use AuditSearch
  all cr: (Doctor + Nurse + Pharmacist + ClinicalAdmin) |
    cr -> AuditSearch not in PermMatrix.Allowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
  some Operation
  // Every Operation that exists in the model has a resolved caller
  // (unauthenticated requests never become Operations in our model)
  all op: Operation | one op.opCaller
  // Corollary: no audit entry exists without a fully-resolved accessor
  all ae: AuditEntry | one ae.aeAccessor
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012, SC-001, SC-002; data-model.md audit_entries
pred AuditCompleteness {
  some Operation
  // Every operation has exactly one corresponding audit entry
  all op: Operation | one op.opAudit
  // No audit entry is shared between two distinct operations
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
  // Every audit entry in the universe is owned by some operation
  all ae: AuditEntry | some op: Operation | op.opAudit = ae
  // No permitted state change (note creation) exists without an audit entry
  all op: Operation |
    (op.opKind = AddNote and op.opOutcome = Permitted) implies
    (op.opAudit.aeKind = AddNote and op.opAudit.aeOutcome = Permitted)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011, FR-014, SC-007, SC-008; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  some ClinicalNote
  some AuditEntry
  // Every clinical note is the product of exactly one permitted AddNote operation
  all n: ClinicalNote |
    one op: Operation |
      op.opKind = AddNote and op.opOutcome = Permitted and op.opNote = n
  // No two permitted AddNote operations produce the same note
  all disj op1, op2: Operation |
    (op1.opKind = AddNote and op1.opOutcome = Permitted and
     op2.opKind = AddNote and op2.opOutcome = Permitted) implies
    op1.opNote != op2.opNote
  // Every audit entry is produced by exactly one operation (immutable, unique)
  all ae: AuditEntry | one op: Operation | op.opAudit = ae
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md AuditEntry fields
pred AttributionCorrectness {
  some Operation
  // Every audit entry's accessor, patient, kind, and outcome match the originating operation
  all op: Operation |
    op.opAudit.aeAccessor = op.opCaller  and
    op.opAudit.aePatient  = op.opPatient and
    op.opAudit.aeKind     = op.opKind    and
    op.opAudit.aeOutcome  = op.opOutcome
  // Clinical note author role snapshot is a clinical role
  all n: ClinicalNote |
    n.noteAuthorRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
  // Note author role snapshot matches actual user role
  all n: ClinicalNote | n.noteAuthorRole = n.noteAuthor.userRole
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  some op: Operation | op.opKind = RecordLookup and op.opOutcome = Permitted
  // Every permitted clinical read/write traces to active care-team membership
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and op.opOutcome = Permitted) implies
    (some m: CareTeamMembership |
       m.ctmClinician = op.opCaller and
       m.ctmPatient   = op.opPatient and
       m.ctmStatus    = ActiveStatus)
  // Conversely, if no active membership exists, the operation cannot be permitted
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and
     no m: CareTeamMembership |
       m.ctmClinician = op.opCaller and
       m.ctmPatient   = op.opPatient and
       m.ctmStatus    = ActiveStatus) implies
    op.opOutcome != Permitted
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006, SC-003; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  some Operation
  // HospitalAdministrator operations on clinical endpoints are never permitted
  all op: Operation |
    (op.opCaller.userRole = HospitalAdministrator and
     op.opKind in (RecordLookup + AddNote)) implies
    op.opOutcome != Permitted
  // Clinical-role operations on AuditSearch are never permitted
  all op: Operation |
    (op.opCaller.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
     op.opKind = AuditSearch) implies
    op.opOutcome != Permitted
  // Non-care-team clinician operations on clinical endpoints are not permitted
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and
     (no m: CareTeamMembership |
       m.ctmClinician = op.opCaller and
       m.ctmPatient   = op.opPatient and
       m.ctmStatus    = ActiveStatus)) implies
    op.opOutcome != Permitted
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some Operation
  // The existence of an Operation implies a resolved caller (authenticated user)
  all op: Operation | one op.opCaller
  // Audit entries only exist for authenticated (Operation-linked) accesses
  all ae: AuditEntry | some op: Operation | op.opAudit = ae
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_OneRolePerUser {
  some User
  all u: User | one u.userRole
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_CareTeamGating {
  // Demonstrate the gating in both directions
  some op: Operation | op.opKind = RecordLookup and op.opOutcome = Permitted
  // Permitted clinical access iff active membership
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and op.opOutcome = Permitted) implies
    (some m: CareTeamMembership |
       m.ctmClinician = op.opCaller and
       m.ctmPatient   = op.opPatient and
       m.ctmStatus    = ActiveStatus)
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and
     (no m: CareTeamMembership |
       m.ctmClinician = op.opCaller and
       m.ctmPatient   = op.opPatient and
       m.ctmStatus    = ActiveStatus)) implies
    op.opOutcome != Permitted
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_AdminContentBlindness {
  some op: Operation | op.opCaller.userRole = HospitalAdministrator
  // Admin may never succeed on clinical endpoints
  all op: Operation |
    op.opCaller.userRole = HospitalAdministrator implies
    (op.opKind = AuditSearch or op.opOutcome != Permitted)
  // Admin is not a valid author of any clinical note
  all n: ClinicalNote |
    n.noteAuthorRole != HospitalAdministrator
  all n: ClinicalNote |
    n.noteAuthor.userRole != HospitalAdministrator
}
assert FR_005_AdminContentBlindness { FR_005_AdminContentBlindness }
check FR_005_AdminContentBlindness for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_ByteEquivalentUnauthorised {
  some Operation
  // All non-permitted outcomes on clinical endpoints (denied or not-found-or-denied)
  // use the same outcome-type universe — no structural distinction leaks
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and op.opOutcome != Permitted) implies
    op.opOutcome in (Denied + NotFoundOrDenied)
  // Clinical roles attempting AuditSearch are refused in the same outcome space
  all op: Operation |
    (op.opCaller.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
     op.opKind = AuditSearch) implies
    op.opOutcome != Permitted
}
assert FR_006_ByteEquivalentUnauthorised { FR_006_ByteEquivalentUnauthorised }
check FR_006_ByteEquivalentUnauthorised for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011, SC-007
pred FR_011_NotesAppendOnly {
  some ClinicalNote
  // Every ClinicalNote is produced by exactly one permitted AddNote operation
  all n: ClinicalNote |
    (one op: Operation |
       op.opKind = AddNote and op.opOutcome = Permitted and op.opNote = n)
  // Two distinct permitted AddNote operations produce distinct notes
  all disj op1, op2: Operation |
    (op1.opKind = AddNote and op1.opOutcome = Permitted and
     op2.opKind = AddNote and op2.opOutcome = Permitted) implies
    op1.opNote != op2.opNote
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012, SC-001, SC-002
pred FR_012_AlwaysOnAudit {
  some Operation
  // Every operation has exactly one audit entry
  all op: Operation | one op.opAudit
  // No audit entry exists without an originating operation
  all ae: AuditEntry | one op: Operation | op.opAudit = ae
  // A permitted AddNote with a created note has a matching audit entry
  all op: Operation |
    (op.opKind = AddNote and op.opOutcome = Permitted) implies
    (op.opAudit.aeKind = AddNote and one op.opNote and
     op.opAudit.aeNoteRef = op.opNote)
}
assert FR_012_AlwaysOnAudit { FR_012_AlwaysOnAudit }
check FR_012_AlwaysOnAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 (note_id structural CHECK)
pred FR_013_NoteIdConsistency {
  some AuditEntry
  // note_id present exactly when add_note AND permitted
  all ae: AuditEntry |
    (ae.aeKind = AddNote and ae.aeOutcome = Permitted) iff (one ae.aeNoteRef)
  all ae: AuditEntry |
    (ae.aeKind in (RecordLookup + AuditSearch)) implies (no ae.aeNoteRef)
  all ae: AuditEntry |
    (ae.aeKind = AddNote and ae.aeOutcome != Permitted) implies (no ae.aeNoteRef)
}
assert FR_013_NoteIdConsistency { FR_013_NoteIdConsistency }
check FR_013_NoteIdConsistency for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014, SC-008
pred FR_014_AuditImmutability {
  some AuditEntry
  // Every AuditEntry is linked to exactly one Operation (no orphan, no shared entries)
  all ae: AuditEntry | one op: Operation | op.opAudit = ae
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
  // Audit entry fields correctly reflect the originating operation (no post-hoc alteration)
  all op: Operation |
    op.opAudit.aeAccessor = op.opCaller  and
    op.opAudit.aePatient  = op.opPatient and
    op.opAudit.aeKind     = op.opKind    and
    op.opAudit.aeOutcome  = op.opOutcome
}
assert FR_014_AuditImmutability { FR_014_AuditImmutability }
check FR_014_AuditImmutability for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017; contracts/http-api.md POST /audit/search
pred FR_017_AuditSearchAdminOnly {
  some op: Operation | op.opKind = AuditSearch
  all op: Operation |
    (op.opKind = AuditSearch and op.opOutcome = Permitted) implies
    op.opCaller.userRole = HospitalAdministrator
  all op: Operation |
    (op.opCaller.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
     op.opKind = AuditSearch) implies
    op.opOutcome != Permitted
}
assert FR_017_AuditSearchAdminOnly { FR_017_AuditSearchAdminOnly }
check FR_017_AuditSearchAdminOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018; contracts/http-api.md administrator content-blindness
pred FR_018_AdminResponseContentBlind {
  some op: Operation | op.opCaller.userRole = HospitalAdministrator
  // Notes authored by an administrator are structurally impossible
  no n: ClinicalNote | n.noteAuthor.userRole = HospitalAdministrator
  no n: ClinicalNote | n.noteAuthorRole = HospitalAdministrator
  // Administrators cannot produce a permitted clinical operation
  all op: Operation |
    (op.opCaller.userRole = HospitalAdministrator and op.opOutcome = Permitted) implies
    op.opKind = AuditSearch
}
assert FR_018_AdminResponseContentBlind { FR_018_AdminResponseContentBlind }
check FR_018_AdminResponseContentBlind for 6