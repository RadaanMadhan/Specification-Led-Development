// === feature_model.als — Alloy model for Hospital Clinical Record Access ===
// Feature ID: C-L2
// Branch: 012-hospital-clinical-records
// Artefacts: spec.md, data-model.md, contracts/http-api.md

// ── Roles ─────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator extends Role {}

// ── Operation kinds (the three endpoints) ────────────────────────────────────
abstract sig OperationKind {}
one sig RecordsLookup, RecordsNotes, AuditSearch extends OperationKind {}

// ── Access outcomes ───────────────────────────────────────────────────────────
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// ── Access types (mirroring AccessType enum in data-model.md) ─────────────────
abstract sig AccessType {}
one sig ReadAT, AddNoteAT, ListAuditAT extends AccessType {}

// ── Note types (fixed v1 catalogue) ──────────────────────────────────────────
abstract sig NoteType {}
one sig Progress, Assessment, Plan, Observation, DischargeSummary extends NoteType {}

// ── Users ─────────────────────────────────────────────────────────────────────
sig User {
  role: one Role
}

// ── Patients ──────────────────────────────────────────────────────────────────
sig Patient {}

// ── Active care-team memberships ─────────────────────────────────────────────
// Only ACTIVE rows are represented (the feature fail-closes on missing rows).
sig CareTeamMembership {
  ctmClinician : one User,
  ctmPatient   : one Patient
}

// ── Clinical notes (append-only) ──────────────────────────────────────────────
sig ClinicalNote {
  notePatient : one Patient,
  noteAuthor  : one User,
  noteType    : one NoteType
}

// ── Audit entries (immutable) ─────────────────────────────────────────────────
sig AuditEntry {
  aeAccessor    : one User,
  aePatient     : one Patient,
  aeAccessType  : one AccessType,
  aeOutcome     : one AccessOutcome,
  aeNoteRef     : lone ClinicalNote   // set only for add_note + permitted
}

// ── Operations (every endpoint invocation) ────────────────────────────────────
sig Operation {
  opCaller   : one User,
  opKind     : one OperationKind,
  opPatient  : one Patient,
  opOutcome  : one AccessOutcome,
  opAudit    : one AuditEntry          // one-to-one link to its audit entry
}

// ── Permission matrix ─────────────────────────────────────────────────────────
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NonEmptyUniverse — force at least one atom of every dynamic sig
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
// F_PermissionMatrix — closed-world role→operation permission table
// Source: contracts/http-api.md authorisation sections; FR-004, FR-005, FR-017
// ─────────────────────────────────────────────────────────────────────────────
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor             -> RecordsLookup)  +
    (Doctor             -> RecordsNotes)   +
    (Nurse              -> RecordsLookup)  +
    (Nurse              -> RecordsNotes)   +
    (Pharmacist         -> RecordsLookup)  +
    (Pharmacist         -> RecordsNotes)   +
    (ClinicalAdmin      -> RecordsLookup)  +
    (ClinicalAdmin      -> RecordsNotes)   +
    (HospitalAdministrator -> AuditSearch)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_OperationRoleCompliance — every permitted operation fits the role matrix
// Source: spec.md FR-004, FR-005, FR-017; contracts/http-api.md auth sections
// ─────────────────────────────────────────────────────────────────────────────
fact F_OperationRoleCompliance {
  all op: Operation |
    op.opOutcome = Permitted implies
      (op.opCaller.role -> op.opKind) in PermMatrix.Allowed
}

// ─────────────────────────────────────────────────────────────────────────────
// F_CareTeamGating — clinical endpoints only permitted for active care-team members
// Source: spec.md FR-004; data-model.md CareTeamMembership
// ─────────────────────────────────────────────────────────────────────────────
fact F_CareTeamGating {
  all op: Operation |
    (op.opKind = RecordsLookup or op.opKind = RecordsNotes) and
    op.opOutcome = Permitted implies
      (some m: CareTeamMembership |
        m.ctmClinician = op.opCaller and m.ctmPatient = op.opPatient)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AdminCannotAccessClinical — HospitalAdministrator cannot have a permitted
// outcome on clinical endpoints (record-read or note-addition)
// Source: spec.md FR-005; contracts/http-api.md byte-equivalent 404 for admin
// ─────────────────────────────────────────────────────────────────────────────
fact F_AdminCannotAccessClinical {
  all op: Operation |
    op.opCaller.role = HospitalAdministrator implies
      (op.opKind != RecordsLookup and op.opKind != RecordsNotes)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_ClinicalRoleCannotAuditSearch — clinical roles cannot have a permitted
// outcome on AuditSearch
// Source: spec.md FR-017; contracts/http-api.md POST /audit/search authorisation
// ─────────────────────────────────────────────────────────────────────────────
fact F_ClinicalRoleCannotAuditSearch {
  all op: Operation |
    (op.opCaller.role = Doctor or op.opCaller.role = Nurse or
     op.opCaller.role = Pharmacist or op.opCaller.role = ClinicalAdmin) implies
      op.opKind != AuditSearch
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditCorrespondence — each Operation has exactly one matching AuditEntry;
// each AuditEntry belongs to exactly one Operation.
// Source: spec.md FR-012; data-model.md AuditEntry; SC-001, SC-002
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditCorrespondence { /* MUTATED — body cleared by validator */ }

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditAccessTypeMapping — operation kind maps to the correct audit access_type
// Source: spec.md FR-013; data-model.md AccessType enum
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditAccessTypeMapping {
  all op: Operation | {
    op.opKind = RecordsLookup implies op.opAudit.aeAccessType = ReadAT
    op.opKind = RecordsNotes   implies op.opAudit.aeAccessType = AddNoteAT
    op.opKind = AuditSearch    implies op.opAudit.aeAccessType = ListAuditAT
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditNoteIdRule — aeNoteRef is set IFF access_type=add_note AND outcome=permitted
// Source: spec.md FR-013; data-model.md AuditEntry structural CHECK
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditNoteIdRule {
  all ae: AuditEntry | {
    (ae.aeAccessType = AddNoteAT and ae.aeOutcome = Permitted) implies
      (one ae.aeNoteRef)
    (ae.aeAccessType = AddNoteAT and ae.aeOutcome != Permitted) implies
      (no ae.aeNoteRef)
    ae.aeAccessType != AddNoteAT implies (no ae.aeNoteRef)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NoteAuthorRole — only clinical roles (not HospitalAdministrator) can author notes
// Source: spec.md FR-005, FR-010; data-model.md ClinicalNote author_role CHECK
// ─────────────────────────────────────────────────────────────────────────────
fact F_NoteAuthorRole {
  all n: ClinicalNote |
    n.noteAuthor.role != HospitalAdministrator
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AppendOnlyNotes — every ClinicalNote in the system was created by a permitted
// add_note operation; no note exists without a corresponding creation audit trail
// Source: spec.md FR-011; data-model.md ClinicalNote append-only enforcement; SC-007
// ─────────────────────────────────────────────────────────────────────────────
fact F_AppendOnlyNotes {
  all n: ClinicalNote |
    some ae: AuditEntry |
      ae.aeNoteRef = n and
      ae.aeAccessType = AddNoteAT and
      ae.aeOutcome = Permitted
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AppendOnlyAuditEntries — every AuditEntry is owned by exactly one Operation;
// no operation kind in the closed set can modify an existing AuditEntry
// Source: spec.md FR-014; data-model.md AuditEntry immutability; SC-008
// ─────────────────────────────────────────────────────────────────────────────
fact F_AppendOnlyAuditEntries {
  // AuditEntry ownership already enforced by F_AuditCorrespondence (injective);
  // this fact adds: the closed OperationKind set contains no "edit/delete audit" kind
  // (RecordsLookup, RecordsNotes, AuditSearch are the only three that exist).
  // Structural: no two distinct operations share the same AuditEntry.
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NoInformationLeakage — for non-permitted clinical operations, the outcome
// does not reveal whether the patient exists or not. Both Denied and
// NotFoundOrDenied collapse to the same observable (byte-equivalent 404).
// Encoded as: every non-permitted clinical operation's outcome is one of
// {Denied, NotFoundOrDenied}, and no clinical content is reachable.
// Source: spec.md FR-006; contracts/http-api.md byte-equivalent not-found response; SC-003
// ─────────────────────────────────────────────────────────────────────────────
fact F_NoInformationLeakage {
  all op: Operation |
    (op.opKind = RecordsLookup or op.opKind = RecordsNotes) and
    op.opOutcome != Permitted implies
      (op.opOutcome = Denied or op.opOutcome = NotFoundOrDenied)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_ValidationBeforeMutation — a denied or not-found outcome on RecordsNotes
// produces no ClinicalNote (no note is persisted on non-permitted add_note).
// Source: spec.md FR-009, FR-015; contracts/http-api.md POST /records/notes behaviour
// ─────────────────────────────────────────────────────────────────────────────
fact F_ValidationBeforeMutation {
  all op: Operation |
    op.opKind = RecordsNotes and op.opOutcome != Permitted implies
      (no n: ClinicalNote |
        some ae: AuditEntry |
          ae = op.opAudit and ae.aeNoteRef = n)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditSearchPermittedOutcomeOnly — AuditSearch operations always yield Permitted
// (admins who pass auth always get the audit list; the "empty" case is 404 but
// modelled as "no audit entries exist for that patient", not as Denied)
// Source: spec.md FR-017; contracts/http-api.md POST /audit/search behaviour step 4
// ─────────────────────────────────────────────────────────────────────────────
fact F_AuditSearchPermittedOutcomeOnly {
  all op: Operation |
    op.opKind = AuditSearch implies op.opOutcome = Permitted
}

// ─────────────────────────────────────────────────────────────────────────────
// F_CareTeamMembersAreClinical — only clinical-role users appear in care-team rows
// Source: spec.md FR-002, FR-004; data-model.md CareTeamMembership
// ─────────────────────────────────────────────────────────────────────────────
fact F_CareTeamMembersAreClinical {
  all m: CareTeamMembership |
    m.ctmClinician.role != HospitalAdministrator
}

// ─────────────────────────────────────────────────────────────────────────────
// ═══════════════════════ PREDICATES AND ASSERTIONS ════════════════════════════
// ─────────────────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation sections; spec.md FR-004, FR-005, FR-017
pred LeastPrivilege {
  // Every permitted operation's role is in the permission matrix for that endpoint
  some Operation
  all op: Operation |
    op.opOutcome = Permitted implies
      (op.opCaller.role -> op.opKind) in PermMatrix.Allowed
  // HospitalAdministrator has no permitted access to clinical endpoints
  no op: Operation |
    op.opCaller.role = HospitalAdministrator and
    (op.opKind = RecordsLookup or op.opKind = RecordsNotes) and
    op.opOutcome = Permitted
  // Clinical roles have no permitted access to AuditSearch
  no op: Operation |
    (op.opCaller.role = Doctor or op.opCaller.role = Nurse or
     op.opCaller.role = Pharmacist or op.opCaller.role = ClinicalAdmin) and
    op.opKind = AuditSearch and
    op.opOutcome = Permitted
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004, FR-005, FR-017
pred PermissionCompleteness {
  // Every (Role × OperationKind) pair is either explicitly in Allowed or not — no undefined cells.
  // Verified by the closed-world assignment in F_PermissionMatrix.
  some Operation
  // HospitalAdministrator + AuditSearch must be in Allowed
  HospitalAdministrator -> AuditSearch in PermMatrix.Allowed
  // Clinical roles + clinical endpoints must be in Allowed
  Doctor -> RecordsLookup in PermMatrix.Allowed
  Doctor -> RecordsNotes in PermMatrix.Allowed
  // HospitalAdministrator must NOT be in Allowed for clinical endpoints
  not (HospitalAdministrator -> RecordsLookup in PermMatrix.Allowed)
  not (HospitalAdministrator -> RecordsNotes in PermMatrix.Allowed)
  // Clinical roles must NOT be in Allowed for AuditSearch
  not (Doctor -> AuditSearch in PermMatrix.Allowed)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-004, FR-005, FR-017; contracts/http-api.md
pred PermissionGrounding {
  // Every Allowed entry traces to an FR.
  // RecordsLookup/RecordsNotes for clinical roles → FR-004
  // AuditSearch for HospitalAdministrator → FR-005, FR-017
  some Operation
  all r: Role, k: OperationKind |
    (r -> k) in PermMatrix.Allowed implies
      ((r = Doctor or r = Nurse or r = Pharmacist or r = ClinicalAdmin) and
       (k = RecordsLookup or k = RecordsNotes)) or
      (r = HospitalAdministrator and k = AuditSearch)
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
  // Every Operation has a caller with a known role; unauthenticated calls never reach Operations.
  // In the model, every Operation has exactly one User caller.
  some Operation
  all op: Operation | one op.opCaller
  all op: Operation | one op.opCaller.role
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012, FR-013; data-model.md AuditEntry; SC-001, SC-002
pred AuditCompleteness {
  // Every Operation has exactly one AuditEntry linked to it.
  some Operation
  all op: Operation | one op.opAudit
  // Each AuditEntry belongs to exactly one Operation.
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
  // The AuditEntry correctly records the operation's caller, patient, and outcome.
  all op: Operation | {
    op.opAudit.aeAccessor = op.opCaller
    op.opAudit.aePatient  = op.opPatient
    op.opAudit.aeOutcome  = op.opOutcome
  }
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011, FR-014; data-model.md append-only enforcement; SC-007, SC-008
pred AppendOnly {
  // Every ClinicalNote in the system was created by a permitted add_note operation.
  some ClinicalNote
  all n: ClinicalNote |
    (some ae: AuditEntry |
      ae.aeNoteRef = n and
      ae.aeAccessType = AddNoteAT and
      ae.aeOutcome = Permitted)
  // No two distinct operations share an AuditEntry (each entry is written once).
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md AuditEntry snapshot fields
pred AttributionCorrectness {
  // Every AuditEntry's accessor matches the caller of the Operation it records.
  some AuditEntry
  all ae: AuditEntry |
    (one op: Operation |
      op.opAudit = ae and
      ae.aeAccessor = op.opCaller and
      ae.aePatient  = op.opPatient and
      ae.aeOutcome  = op.opOutcome)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  // Every permitted clinical operation has a care-team membership row linking caller to patient.
  some op: Operation |
    (op.opKind = RecordsLookup or op.opKind = RecordsNotes) and
    op.opOutcome = Permitted
  all op: Operation |
    (op.opKind = RecordsLookup or op.opKind = RecordsNotes) and
    op.opOutcome = Permitted implies
      (some m: CareTeamMembership |
        m.ctmClinician = op.opCaller and m.ctmPatient = op.opPatient)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006; contracts/http-api.md byte-equivalent not-found; SC-003
pred NoInformationLeakage {
  // For non-permitted clinical operations, outcome is always Denied or NotFoundOrDenied
  // — never any clinical content is distinguishable.
  some op: Operation |
    (op.opKind = RecordsLookup or op.opKind = RecordsNotes) and
    op.opOutcome != Permitted
  all op: Operation |
    (op.opKind = RecordsLookup or op.opKind = RecordsNotes) and
    op.opOutcome != Permitted implies
      (op.opOutcome = Denied or op.opOutcome = NotFoundOrDenied)
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-009, FR-015; contracts/http-api.md POST /records/notes
pred ValidationBeforeMutation {
  // A non-permitted RecordsNotes operation produces no ClinicalNote.
  some op: Operation | op.opKind = RecordsNotes and op.opOutcome != Permitted
  all op: Operation |
    op.opKind = RecordsNotes and op.opOutcome != Permitted implies
      (no n: ClinicalNote |
        some ae: AuditEntry |
          ae = op.opAudit and ae.aeNoteRef = n)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  // All Operations have an authenticated caller — no null/undefined caller.
  some Operation
  all op: Operation | some op.opCaller and some op.opCaller.role
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_OneRolePerUser {
  // Every user has exactly one role.
  some User
  all u: User | one u.role
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_CareTeamGating {
  // Permitted clinical access exists and always has a care-team membership row.
  some op: Operation |
    (op.opKind = RecordsLookup or op.opKind = RecordsNotes) and
    op.opOutcome = Permitted
  all op: Operation |
    (op.opKind = RecordsLookup or op.opKind = RecordsNotes) and
    op.opOutcome = Permitted implies
      (some m: CareTeamMembership |
        m.ctmClinician = op.opCaller and m.ctmPatient = op.opPatient)
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_AdminNoClinicalContent {
  // HospitalAdministrator has no permitted operation on RecordsLookup or RecordsNotes.
  some op: Operation | op.opCaller.role = HospitalAdministrator
  no op: Operation |
    op.opCaller.role = HospitalAdministrator and
    (op.opKind = RecordsLookup or op.opKind = RecordsNotes)
}
assert FR_005_AdminNoClinicalContent { FR_005_AdminNoClinicalContent }
check FR_005_AdminNoClinicalContent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006; SC-003
pred FR_006_ByteEquivalentUnauthorised {
  // Non-permitted clinical operations always yield Denied or NotFoundOrDenied, never Permitted.
  some op: Operation |
    (op.opKind = RecordsLookup or op.opKind = RecordsNotes) and
    op.opOutcome != Permitted
  all op: Operation |
    (op.opKind = RecordsLookup or op.opKind = RecordsNotes) and
    op.opOutcome != Permitted implies
      (op.opOutcome = Denied or op.opOutcome = NotFoundOrDenied)
}
assert FR_006_ByteEquivalentUnauthorised { FR_006_ByteEquivalentUnauthorised }
check FR_006_ByteEquivalentUnauthorised for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009; FR-010
pred FR_009_NoteValidation {
  // Every ClinicalNote has an author with a clinical role and is linked to a permitted audit entry.
  some ClinicalNote
  all n: ClinicalNote |
    n.noteAuthor.role != HospitalAdministrator
  all n: ClinicalNote |
    (some ae: AuditEntry |
      ae.aeNoteRef = n and
      ae.aeAccessType = AddNoteAT and
      ae.aeOutcome = Permitted)
}
assert FR_009_NoteValidation { FR_009_NoteValidation }
check FR_009_NoteValidation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011; SC-007
pred FR_011_NotesAppendOnly {
  // Every note is created once (linked to exactly one audit entry via aeNoteRef).
  some ClinicalNote
  all n: ClinicalNote |
    one ae: AuditEntry | ae.aeNoteRef = n
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012; SC-001; SC-002
pred FR_012_AlwaysOnAudit {
  // Every Operation has exactly one AuditEntry, and every AuditEntry is from one Operation.
  some Operation
  all op: Operation | one op.opAudit
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
}
assert FR_012_AlwaysOnAudit { FR_012_AlwaysOnAudit }
check FR_012_AlwaysOnAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013; data-model.md AuditEntry structural CHECK
pred FR_013_AuditNoteIdRule {
  // note_id is set if and only if access_type=add_note AND outcome=permitted.
  some ae: AuditEntry | ae.aeAccessType = AddNoteAT and ae.aeOutcome = Permitted
  all ae: AuditEntry | {
    (ae.aeAccessType = AddNoteAT and ae.aeOutcome = Permitted) implies (one ae.aeNoteRef)
    (ae.aeAccessType = AddNoteAT and ae.aeOutcome != Permitted) implies (no ae.aeNoteRef)
    ae.aeAccessType != AddNoteAT implies (no ae.aeNoteRef)
  }
}
assert FR_013_AuditNoteIdRule { FR_013_AuditNoteIdRule }
check FR_013_AuditNoteIdRule for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014; SC-008
pred FR_014_AuditImmutability {
  // Each AuditEntry is owned by exactly one Operation (no duplication, no sharing).
  some AuditEntry
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
}
assert FR_014_AuditImmutability { FR_014_AuditImmutability }
check FR_014_AuditImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017; contracts/http-api.md POST /audit/search
pred FR_017_AdminOnlyAuditSearch {
  // Only HospitalAdministrator may have operations of kind AuditSearch.
  some op: Operation | op.opKind = AuditSearch
  all op: Operation |
    op.opKind = AuditSearch implies op.opCaller.role = HospitalAdministrator
}
assert FR_017_AdminOnlyAuditSearch { FR_017_AdminOnlyAuditSearch }
check FR_017_AdminOnlyAuditSearch for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018; spec.md FR-005; SC-006
pred FR_018_AdminContentBlindness {
  // Administrator AuditSearch operations produce no ClinicalNote content in their audit entry.
  some op: Operation | op.opKind = AuditSearch
  all op: Operation |
    op.opKind = AuditSearch implies (no op.opAudit.aeNoteRef)
}
assert FR_018_AdminContentBlindness { FR_018_AdminContentBlindness }
check FR_018_AdminContentBlindness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010; data-model.md ClinicalNote author_role CHECK
pred FR_010_NoteAuthorClinicalRole {
  // Notes can only be authored by clinical-role users (not HospitalAdministrator).
  some ClinicalNote
  all n: ClinicalNote | n.noteAuthor.role != HospitalAdministrator
}
assert FR_010_NoteAuthorClinicalRole { FR_010_NoteAuthorClinicalRole }
check FR_010_NoteAuthorClinicalRole for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015; SC-009; contracts/http-api.md 503 behaviour
pred FR_015_AuditAtomicWithOperation {
  // There is no Operation without a matching AuditEntry (atomicity guarantee).
  // Encoded as: the opAudit mapping is total and injective.
  some Operation
  all op: Operation | one op.opAudit
  // And each audit belongs to exactly one op (so no "orphan" audit exists without an op).
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
}
assert FR_015_AuditAtomicWithOperation { FR_015_AuditAtomicWithOperation }
check FR_015_AuditAtomicWithOperation for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-002; data-model.md User
pred FR_002_UserHasExactlyOneRole {
  // Exactly one role per user; no multi-role, no role inheritance.
  some User
  all u: User | one u.role
}
assert FR_002_UserHasExactlyOneRole { FR_002_UserHasExactlyOneRole }
check FR_002_UserHasExactlyOneRole for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md assumptions (no break-glass); FR-004
pred NoCareTeamOverride {
  // There is no permitted clinical access without a care-team membership row —
  // no emergency override, no role-based bypass.
  some op: Operation |
    (op.opKind = RecordsLookup or op.opKind = RecordsNotes) and
    op.opOutcome = Permitted
  all op: Operation |
    (op.opKind = RecordsLookup or op.opKind = RecordsNotes) and
    op.opOutcome = Permitted implies
      (some m: CareTeamMembership |
        m.ctmClinician = op.opCaller and m.ctmPatient = op.opPatient)
}
assert NoCareTeamOverride { NoCareTeamOverride }
check NoCareTeamOverride for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-004; data-model.md CareTeamMembership
pred CareTeamMembersAreClinical {
  // Only users with clinical roles appear in CareTeamMembership rows.
  some CareTeamMembership
  all m: CareTeamMembership | m.ctmClinician.role != HospitalAdministrator
}
assert CareTeamMembersAreClinical { CareTeamMembersAreClinical }
check CareTeamMembersAreClinical for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AuditCorrespondenceViolation { some op: Operation | op.opAudit.aeAccessor != op.opCaller }
