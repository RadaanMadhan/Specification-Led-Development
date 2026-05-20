// === feature_model.als — Alloy 6 model for Hospital Clinical Record Access (C-L2) ===
// Branch: 012-hospital-clinical-records
// Sources: spec.md, data-model.md, contracts/http-api.md

// ─── Role catalogue (FR-002, data-model.md UserRole enum) ────────────────────
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator extends Role {}

// Helper: the four clinical roles
fun ClinicalRoles : set Role { Doctor + Nurse + Pharmacist + ClinicalAdmin }

// ─── Endpoint / operation kinds ───────────────────────────────────────────────
abstract sig OperationKind {}
one sig RecordsLookup, RecordsNotes, AuditSearch extends OperationKind {}

// ─── Access-type labels (data-model.md AccessType enum) ───────────────────────
abstract sig AccessType {}
one sig Read, AddNote, ListAudit extends AccessType {}

// ─── Outcome labels (data-model.md AccessOutcome enum) ────────────────────────
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// ─── Authorisation-basis labels (data-model.md AuthorisationBasis enum) ───────
abstract sig AuthBasis {}
one sig CareTeamMember_B, NotCareTeamMember_B, PatientNotFound_B, AdministratorRole_B
    extends AuthBasis {}

// ─── Permission matrix (singleton, contracts/http-api.md authorisation tables) ─
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─── Domain entities ──────────────────────────────────────────────────────────
sig User { userRole: one Role }
sig Patient {}

// ActiveMembership: clinician currently on a patient's active care team (FR-004)
sig ActiveMembership {
  member      : one User,
  memberPatient: one Patient
}

// ClinicalNote: append-only note (FR-009, FR-010, FR-011)
sig ClinicalNote {
  notePatient: one Patient,
  noteAuthor : one User
}

// AuditEntry: immutable record of one access event (FR-012, FR-013, FR-014)
sig AuditEntry {
  auditUser      : one User,
  auditPatient   : one Patient,
  auditAccessType: one AccessType,
  auditOutcome   : one AccessOutcome,
  auditBasis     : one AuthBasis,
  auditNote      : lone ClinicalNote   // set iff AddNote + Permitted (FR-013)
}

// Operation: one authenticated request that reached the service-layer handler.
// Unauthenticated requests are rejected before a handler runs and never
// produce an Operation or AuditEntry (FR-001).
sig Operation {
  opCaller : one User,
  opKind   : one OperationKind,
  opPatient: one Patient,
  opOutcome: one AccessOutcome,
  opAudit  : one AuditEntry
}

// ─── Non-empty universe ───────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
  some User
  some Patient
  some ActiveMembership
  some ClinicalNote
  some AuditEntry
  some Operation
}

// ─── Permission matrix cell set (FR-004, FR-005, FR-017) ──────────────────────
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor              -> RecordsLookup) +
    (Doctor              -> RecordsNotes)  +
    (Nurse               -> RecordsLookup) +
    (Nurse               -> RecordsNotes)  +
    (Pharmacist          -> RecordsLookup) +
    (Pharmacist          -> RecordsNotes)  +
    (ClinicalAdmin       -> RecordsLookup) +
    (ClinicalAdmin       -> RecordsNotes)  +
    (HospitalAdministrator -> AuditSearch)
}

// ─── OperationKind ↔ AccessType bijection ─────────────────────────────────────
fact F_OpKindToAccessType {
  all op: Operation |
    (op.opKind = RecordsLookup implies op.opAudit.auditAccessType = Read)    and
    (op.opKind = RecordsNotes   implies op.opAudit.auditAccessType = AddNote) and
    (op.opKind = AuditSearch    implies op.opAudit.auditAccessType = ListAudit)
}

// ─── AuditSearch: only hospital administrators reach the handler (FR-017) ─────
// Non-admin callers receive byte-equivalent 404 before the handler; no Operation
// atom is created for them.
fact F_AuditSearchAdminOnly {
  all op: Operation |
    op.opKind = AuditSearch implies op.opCaller.userRole = HospitalAdministrator
}

// ─── AuditSearch operations are always Permitted (contracts/http-api.md) ───────
fact F_AuditSearchAlwaysPermitted {
  all op: Operation |
    op.opKind = AuditSearch implies op.opOutcome = Permitted
}

// ─── Care-team gating: clinical Permitted outcome requires active membership ───
fact F_CareTeamGating { /* MUTATED — body cleared by validator */ }

// ─── Converse: no membership → not Permitted on clinical endpoints ─────────────
fact F_NoMembershipNoClinicalAccess {
  all op: Operation |
    (op.opKind in RecordsLookup + RecordsNotes and
     no m: ActiveMembership |
       m.member = op.opCaller and m.memberPatient = op.opPatient)
    implies op.opOutcome != Permitted
}

// ─── Only clinical roles may appear in Permitted clinical-endpoint operations ──
fact F_PermittedClinicalRequiresClinicalRole {
  all op: Operation |
    (op.opKind in RecordsLookup + RecordsNotes and op.opOutcome = Permitted) implies
    op.opCaller.userRole in ClinicalRoles
}

// ─── Memberships only contain clinical-role users ─────────────────────────────
fact F_MembershipsAreClinical {
  all m: ActiveMembership | m.member.userRole in ClinicalRoles
}

// ─── Note authors must be clinical-role users (FR-010, data-model.md CHECK) ───
fact F_NoteAuthorIsClinical {
  all n: ClinicalNote | n.noteAuthor.userRole in ClinicalRoles
}

// ─── Notes require a corresponding Permitted add-note operation (FR-011) ───────
fact F_NotesRequirePermittedOp {
  all n: ClinicalNote |
    one op: Operation |
      op.opKind    = RecordsNotes and
      op.opOutcome = Permitted    and
      op.opAudit.auditNote = n    and
      op.opCaller  = n.noteAuthor and
      op.opPatient = n.notePatient
}

// ─── Audit entries are 1-to-1 with operations (injective opAudit) (FR-012) ────
fact F_AuditInjective {
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
}

// ─── Every AuditEntry is the record of exactly one Operation (FR-012) ─────────
fact F_AllAuditEntriesLinked {
  all ae: AuditEntry | one op: Operation | op.opAudit = ae
}

// ─── Attribution: audit entry records the correct user / patient / outcome ─────
fact F_AuditAttribution {
  all op: Operation |
    op.opAudit.auditUser    = op.opCaller  and
    op.opAudit.auditPatient = op.opPatient and
    op.opAudit.auditOutcome = op.opOutcome
}

// ─── note_id rule: auditNote set iff AddNote + Permitted (FR-013) ─────────────
fact F_AuditNoteIdRule {
  all ae: AuditEntry |
    (ae.auditAccessType = AddNote and ae.auditOutcome = Permitted)
    iff (one ae.auditNote)
}

// ─── Authorisation-basis consistency (FR-013) ─────────────────────────────────
fact F_AuthBasisConsistency {
  all op: Operation |
    // Permitted clinical access → care_team_member basis
    (op.opKind in RecordsLookup + RecordsNotes and op.opOutcome = Permitted) implies
      op.opAudit.auditBasis = CareTeamMember_B
  all op: Operation |
    // AuditSearch → administrator_role basis
    op.opKind = AuditSearch implies op.opAudit.auditBasis = AdministratorRole_B
}

// ─── Denied note-addition produces no note and no auditNote reference (FR-009) ─
fact F_DeniedNoteAddProducesNoNote {
  all op: Operation |
    (op.opKind = RecordsNotes and op.opOutcome != Permitted) implies
    op.opAudit.auditNote = none
}

// ═════════════════════════════════════════════════════════════════════════════
//  PREDICATES AND ASSERTIONS
// ═════════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-004, FR-005, FR-017
pred LeastPrivilege {
  some Operation
  // Every Permitted operation has its (role, opKind) cell in the Allowed matrix.
  all op: Operation |
    op.opOutcome = Permitted implies
    (op.opCaller.userRole -> op.opKind in PermMatrix.Allowed)
  // No cell outside the matrix is ever Permitted.
  all op: Operation |
    op.opCaller.userRole -> op.opKind not in PermMatrix.Allowed implies
    op.opOutcome != Permitted
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables; spec.md FR-004, FR-017
pred PermissionCompleteness {
  some Operation
  // The Allowed matrix has exactly the 9 explicitly documented cells.
  #PermMatrix.Allowed = 9
  // Every operation that is Permitted carries a (role, opKind) pair that is
  // documented in the matrix.
  all op: Operation |
    op.opOutcome = Permitted implies
    (op.opCaller.userRole -> op.opKind in PermMatrix.Allowed)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  some Operation
  // Every Operation and its linked AuditEntry carry a real User as caller /
  // accessor — unauthenticated requests never produce an Operation atom.
  all op: Operation | op.opCaller in User
  all ae: AuditEntry | ae.auditUser in User
  // Unauthenticated requests must produce no note and no audit entry:
  // captured structurally — all AuditEntry atoms belong to Operations which
  // require a caller, and all ClinicalNote atoms require a Permitted Operation.
  all n: ClinicalNote | n.noteAuthor in User
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012; data-model.md audit_entries AUTOINCREMENT PK
pred AuditCompleteness {
  some Operation
  // Every operation produces exactly one audit entry.
  all op: Operation | one op.opAudit
  // Every audit entry belongs to exactly one operation (no orphans, no sharing).
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011 (notes), FR-014 (audit); data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  some AuditEntry
  some ClinicalNote
  // Each AuditEntry is owned by exactly one Operation — no entry is ever
  // "re-used" to represent a second event (structural immutability proxy).
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
  // Every AuditEntry has a unique owning operation (no shared / mutated entries).
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
  // Every ClinicalNote is the product of exactly one Permitted add-note operation
  // (append semantics: one creation event, no subsequent mutations).
  all n: ClinicalNote |
    (one op: Operation |
       op.opKind = RecordsNotes and op.opOutcome = Permitted and
       op.opAudit.auditNote = n)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md audit-entry snapshot fields; spec.md FR-013
pred AttributionCorrectness {
  some AuditEntry
  all op: Operation |
    op.opAudit.auditUser    = op.opCaller  and
    op.opAudit.auditPatient = op.opPatient and
    op.opAudit.auditOutcome = op.opOutcome
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md care_team_memberships
pred OwnershipBasedAccess {
  some Operation
  // Permitted clinical access → caller is on the patient's active care team.
  all op: Operation |
    (op.opKind in RecordsLookup + RecordsNotes and op.opOutcome = Permitted) implies
    (some m: ActiveMembership |
       m.member = op.opCaller and m.memberPatient = op.opPatient)
  // No active membership → cannot be Permitted on a clinical endpoint.
  all op: Operation |
    (op.opKind in RecordsLookup + RecordsNotes and
     no m: ActiveMembership |
       m.member = op.opCaller and m.memberPatient = op.opPatient)
    implies op.opOutcome != Permitted
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006; contracts/http-api.md byte-equivalent 404
pred NoInformationLeakage {
  some Operation
  // Hospital administrators are never Permitted on clinical endpoints — they
  // receive the byte-equivalent 404 (FR-006) and cannot distinguish a real
  // patient from a nonexistent one through that response shape.
  all op: Operation |
    (op.opCaller.userRole = HospitalAdministrator and
     op.opKind in RecordsLookup + RecordsNotes)
    implies op.opOutcome != Permitted
  // Clinical-role callers never reach the AuditSearch handler — the endpoint's
  // existence is not signalled to them (FR-006, contracts/http-api.md).
  all op: Operation |
    op.opKind = AuditSearch implies op.opCaller.userRole = HospitalAdministrator
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-009; data-model.md atomicity contract
pred ValidationBeforeMutation {
  some Operation
  // A note exists only when a Permitted add-note operation produced it;
  // denied / not-found note-addition operations leave no note behind.
  all op: Operation |
    (op.opKind = RecordsNotes and op.opOutcome != Permitted) implies
    op.opAudit.auditNote = none
  // Converse: every existing note traces to exactly one Permitted operation.
  all n: ClinicalNote |
    (one op: Operation |
       op.opKind = RecordsNotes and op.opOutcome = Permitted and
       op.opAudit.auditNote = n)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// ─── Feature-specific predicates ─────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some Operation
  // Structural proxy: every Operation's caller is a User atom (authenticated);
  // no Operation or AuditEntry atom can carry a "null" caller.
  all op: Operation | one op.opCaller
  all ae: AuditEntry | one ae.auditUser
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_CareTeamGating {
  some Operation
  // Permitted on clinical endpoints ↔ active care-team membership exists.
  all op: Operation |
    (op.opKind in RecordsLookup + RecordsNotes and op.opOutcome = Permitted) implies
    (some m: ActiveMembership |
       m.member = op.opCaller and m.memberPatient = op.opPatient)
  all op: Operation |
    (op.opKind in RecordsLookup + RecordsNotes and
     no m: ActiveMembership |
       m.member = op.opCaller and m.memberPatient = op.opPatient)
    implies op.opOutcome != Permitted
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005, FR-018
pred FR_005_AdminContentBlindness {
  some Operation
  // Administrator is never Permitted on clinical endpoints.
  all op: Operation |
    op.opCaller.userRole = HospitalAdministrator implies
    op.opKind not in RecordsLookup + RecordsNotes or op.opOutcome != Permitted
  // No ClinicalNote is authored by a HospitalAdministrator.
  no n: ClinicalNote | n.noteAuthor.userRole = HospitalAdministrator
  // All ClinicalNote-authoring operations use a clinical role.
  all op: Operation |
    (op.opKind = RecordsNotes and op.opOutcome = Permitted) implies
    op.opCaller.userRole in ClinicalRoles
}
assert FR_005_AdminContentBlindness { FR_005_AdminContentBlindness }
check FR_005_AdminContentBlindness for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010, data-model.md CHECK(author_role IN clinical roles)
pred FR_010_NoteAuthorClinical {
  some ClinicalNote
  all n: ClinicalNote | n.noteAuthor.userRole in ClinicalRoles
}
assert FR_010_NoteAuthorClinical { FR_010_NoteAuthorClinical }
check FR_010_NoteAuthorClinical for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 append-only notes
pred FR_011_NotesAppendOnly {
  some ClinicalNote
  // Every note is the product of exactly one Permitted RecordsNotes operation.
  all n: ClinicalNote |
    (one op: Operation |
       op.opKind = RecordsNotes and
       op.opOutcome = Permitted  and
       op.opAudit.auditNote = n  and
       op.opCaller  = n.noteAuthor  and
       op.opPatient = n.notePatient)
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012, SC-001, SC-002
pred FR_012_AuditEveryAccess {
  some Operation
  // 1-to-1 between Operations and AuditEntries.
  all op: Operation | one op.opAudit
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
  // No note without a matching audit entry that records it.
  all n: ClinicalNote |
    (some ae: AuditEntry |
       ae.auditNote = n and
       ae.auditOutcome = Permitted and
       ae.auditAccessType = AddNote)
}
assert FR_012_AuditEveryAccess { FR_012_AuditEveryAccess }
check FR_012_AuditEveryAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 note_id structural CHECK
pred FR_013_AuditNoteIdConsistency {
  some AuditEntry
  all ae: AuditEntry |
    (ae.auditAccessType = AddNote and ae.auditOutcome = Permitted) implies
    (one ae.auditNote)
  all ae: AuditEntry |
    (ae.auditAccessType != AddNote or ae.auditOutcome != Permitted) implies
    no ae.auditNote
}
assert FR_013_AuditNoteIdConsistency { FR_013_AuditNoteIdConsistency }
check FR_013_AuditNoteIdConsistency for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 audit immutability; FR-016 retention
pred FR_014_AuditImmutable {
  some AuditEntry
  // Structural immutability: each audit entry is owned by at most one operation,
  // and no two operations share an audit entry (no "overwrite" possible).
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
}
assert FR_014_AuditImmutable { FR_014_AuditImmutable }
check FR_014_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 atomic audit-with-access
pred FR_015_AuditAtomicWithAccess {
  some Operation
  // Every operation has exactly one linked audit entry (atomic commit or rollback).
  all op: Operation | one op.opAudit
  // Every note persisted has a matching audit entry that records it.
  all n: ClinicalNote |
    (some ae: AuditEntry |
       ae.auditNote = n and
       ae.auditOutcome = Permitted and
       ae.auditAccessType = AddNote)
}
assert FR_015_AuditAtomicWithAccess { FR_015_AuditAtomicWithAccess }
check FR_015_AuditAtomicWithAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AuditSearchAdminOnly {
  some Operation
  all op: Operation |
    op.opKind = AuditSearch implies op.opCaller.userRole = HospitalAdministrator
}
assert FR_017_AuditSearchAdminOnly { FR_017_AuditSearchAdminOnly }
check FR_017_AuditSearchAdminOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 attribution (snapshot fields match caller)
pred FR_013_AttributionIntegrity {
  some AuditEntry
  all op: Operation |
    op.opAudit.auditUser    = op.opCaller  and
    op.opAudit.auditPatient = op.opPatient and
    op.opAudit.auditOutcome = op.opOutcome
}
assert FR_013_AttributionIntegrity { FR_013_AttributionIntegrity }
check FR_013_AttributionIntegrity for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_CareTeamViolation { some op: Operation | op.opKind = RecordsLookup and op.opOutcome = Permitted and (no m: ActiveMembership | m.member = op.opCaller and m.memberPatient = op.opPatient) }
