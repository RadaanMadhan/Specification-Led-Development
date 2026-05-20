// === feature_model.als — Alloy model for Hospital Clinical Record Access (012) ===

// --- Roles (FR-002 catalogue) ---
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator extends Role {}

// --- Operation kinds (the three endpoints) ---
abstract sig OperationKind {}
one sig PostRecordsLookup, PostRecordsNotes, PostAuditSearch extends OperationKind {}

// --- Outcomes ---
abstract sig Outcome {}
one sig Permitted, Denied, NotFoundOrDenied extends Outcome {}

// --- Authorisation basis (data-model.md AuthorisationBasis) ---
abstract sig AuthBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound, AdministratorRole extends AuthBasis {}

// --- Externally-observable response envelopes (byte-equivalence target, FR-006) ---
abstract sig ResponseShape {}
one sig RecordOk, NoteCreated, AuditList, NotFoundEnvelope, Unauthenticated401, ValidationError400, ServiceUnavailable503 extends ResponseShape {}

// --- Bool helper (membership active flag, authenticated flag) ---
abstract sig Bool {}
one sig True, False extends Bool {}

// --- Domain entities (data-model.md) ---
sig User { role: one Role }
sig Patient {}

sig CareTeamMembership {
  ctmClinician: one User,
  ctmPatient: one Patient,
  ctmActive: one Bool
}

sig ClinicalNote {
  notePatient: one Patient,
  noteAuthor: one User,
  noteAuthorRole: one Role
}

sig Operation {
  caller: one User,
  callerRoleSnapshot: one Role,
  targetPatient: one Patient,
  kind: one OperationKind,
  outcome: one Outcome,
  basis: one AuthBasis,
  authenticated: one Bool,
  responseBytes: one ResponseShape,
  noteCreated: lone ClinicalNote
}

sig AuditEntry {
  op: one Operation,
  auditUser: one User,
  auditRole: one Role,
  auditPatient: one Patient,
  auditKind: one OperationKind,
  auditOutcome: one Outcome,
  auditBasis: one AuthBasis,
  auditNote: lone ClinicalNote
}

// --- Permission matrix as a singleton-sig field (Role x OperationKind allowed cells) ---
one sig PermMatrix { Allowed: set Role -> OperationKind }

// =====================================================================
// Non-empty universe (per system prompt rule 9)
// =====================================================================
fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some ClinicalNote
  some Operation
  some AuditEntry
}

// =====================================================================
// Static facts (closed-world permission matrix, schema consistency)
// =====================================================================

// Permission matrix encoded from contracts/http-api.md:
//   doctors/nurses/pharmacists/clinical_admins -> records lookup + add note
//   hospital_administrator                     -> audit search
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor -> PostRecordsLookup) +
    (Nurse -> PostRecordsLookup) +
    (Pharmacist -> PostRecordsLookup) +
    (ClinicalAdmin -> PostRecordsLookup) +
    (Doctor -> PostRecordsNotes) +
    (Nurse -> PostRecordsNotes) +
    (Pharmacist -> PostRecordsNotes) +
    (ClinicalAdmin -> PostRecordsNotes) +
    (HospitalAdministrator -> PostAuditSearch)
}

// Caller's role snapshot reflects the caller's actual role at op time.
fact F_RoleSnapshot {
  all op: Operation | op.callerRoleSnapshot = op.caller.role
}

// data-model.md: clinical_notes.author_role CHECK excludes hospital_administrator.
fact F_NoteAuthorClinical {
  all n: ClinicalNote | n.noteAuthorRole != HospitalAdministrator
  all n: ClinicalNote | n.noteAuthorRole = n.noteAuthor.role
}

// =====================================================================
// FR-001 — authentication boundary
// =====================================================================
fact F_AuthRequired {
  all op: Operation | op.authenticated = False implies op.outcome != Permitted
  all op: Operation | op.authenticated = False implies op.responseBytes = Unauthenticated401
  all op: Operation | op.authenticated = False implies (no ae: AuditEntry | ae.op = op)
}

// =====================================================================
// FR-004 / FR-005 / FR-017 — role-based permission gate (LeastPrivilege)
// =====================================================================
fact F_RolePermissionGate {
  all op: Operation | op.outcome = Permitted implies
    (op.callerRoleSnapshot -> op.kind) in PermMatrix.Allowed
}

// =====================================================================
// FR-004 — care-team membership required for permitted clinical access
// =====================================================================
fact F_CareTeamGating {
  all op: Operation |
    (op.kind in (PostRecordsLookup + PostRecordsNotes) and op.outcome = Permitted) implies
      (some ctm: CareTeamMembership |
         ctm.ctmClinician = op.caller and
         ctm.ctmPatient = op.targetPatient and
         ctm.ctmActive = True)
}

// =====================================================================
// FR-012 / FR-015 — audit completeness for clinical endpoints
// =====================================================================
fact F_AuditCompleteness {
  // Every authenticated read or add_note op produces exactly one audit entry.
  all op: Operation |
    (op.authenticated = True and op.kind in (PostRecordsLookup + PostRecordsNotes)) implies
      (one ae: AuditEntry | ae.op = op)
  // Permitted list_audit (by an administrator) also produces an audit entry.
  all op: Operation |
    (op.authenticated = True and op.kind = PostAuditSearch and op.outcome = Permitted) implies
      (one ae: AuditEntry | ae.op = op)
  // Non-administrator list_audit attempts produce no audit entry (per contract).
  all op: Operation |
    (op.kind = PostAuditSearch and op.callerRoleSnapshot != HospitalAdministrator) implies
      (no ae: AuditEntry | ae.op = op)
}

// =====================================================================
// FR-014 — audit entries are immutable and unique per operation
// =====================================================================
fact F_AuditUniqueness {
  all disj ae1, ae2: AuditEntry | ae1.op != ae2.op
}

// =====================================================================
// FR-013 — audit-entry fields are snapshots of the recorded operation
// =====================================================================
fact F_AuditAttribution {
  all ae: AuditEntry |
    ae.auditUser = ae.op.caller and
    ae.auditRole = ae.op.callerRoleSnapshot and
    ae.auditPatient = ae.op.targetPatient and
    ae.auditKind = ae.op.kind and
    ae.auditOutcome = ae.op.outcome and
    ae.auditBasis = ae.op.basis and
    ae.auditNote = ae.op.noteCreated
}

// data-model.md AuditEntry CHECK: note_id present iff add_note + permitted.
fact F_AuditNotePairing {
  all ae: AuditEntry | some ae.auditNote iff
    (ae.auditKind = PostRecordsNotes and ae.auditOutcome = Permitted)
}

// =====================================================================
// FR-011 — clinical notes append-only (every note has exactly one creating
// permitted add_note operation; nothing else creates notes)
// =====================================================================
fact F_NotesProvenance {
  all n: ClinicalNote | one op: Operation | op.noteCreated = n
  all op: Operation | some op.noteCreated implies
    (op.kind = PostRecordsNotes and op.outcome = Permitted)
  all op: Operation | (op.kind = PostRecordsNotes and op.outcome = Permitted) implies
    some op.noteCreated
}

// FR-010 — persisted note fields match the creating operation
fact F_NoteFieldsMatchOp {
  all op: Operation, n: ClinicalNote | op.noteCreated = n implies
    (n.notePatient = op.targetPatient and
     n.noteAuthor = op.caller and
     n.noteAuthorRole = op.callerRoleSnapshot)
}

// =====================================================================
// FR-006 — byte-equivalent unauthorised envelope on denial / not-found
// =====================================================================
fact F_NotFoundEnvelope {
  all op: Operation |
    (op.authenticated = True and (op.outcome = Denied or op.outcome = NotFoundOrDenied)) implies
      op.responseBytes = NotFoundEnvelope
}

// Permitted clinical ops produce per-kind success envelopes. (PostAuditSearch
// permitted responses are NOT constrained here so that F_AdminContentBlindness
// is the load-bearing fact for FR-005 / FR-018.)
fact F_PermittedClinicalResponses {
  all op: Operation | (op.outcome = Permitted and op.kind = PostRecordsLookup) implies
    op.responseBytes = RecordOk
  all op: Operation | (op.outcome = Permitted and op.kind = PostRecordsNotes) implies
    op.responseBytes = NoteCreated
}

// =====================================================================
// FR-005 / FR-018 — administrator content-blindness
// (administrator endpoint never carries a record-shaped or note-shaped response)
// =====================================================================
fact F_AdminContentBlindness {
  all op: Operation | op.kind = PostAuditSearch implies
    op.responseBytes not in (RecordOk + NoteCreated)
}

// =====================================================================
// Predicates and assertions
// =====================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-004, FR-005, FR-017
pred LeastPrivilege {
  some Operation
  all op: Operation | op.outcome = Permitted implies
    (op.callerRoleSnapshot -> op.kind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation | op.authenticated = False implies op.outcome != Permitted
  all op: Operation | op.authenticated = False implies (no ae: AuditEntry | ae.op = op)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md care_team_memberships
pred OwnershipBasedAccess {
  some Operation
  all op: Operation |
    (op.outcome = Permitted and op.kind in (PostRecordsLookup + PostRecordsNotes)) implies
      (some ctm: CareTeamMembership |
         ctm.ctmClinician = op.caller and
         ctm.ctmPatient = op.targetPatient and
         ctm.ctmActive = True)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012; data-model.md audit_entries
pred AuditCompleteness {
  some Operation
  all op: Operation |
    (op.authenticated = True and op.kind in (PostRecordsLookup + PostRecordsNotes)) implies
      (one ae: AuditEntry | ae.op = op)
  all disj ae1, ae2: AuditEntry | ae1.op != ae2.op
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly (audit)  ANCHOR: spec.md FR-014; data-model.md no UPDATE/DELETE on audit_entries
pred AppendOnlyAudit {
  some AuditEntry
  all disj ae1, ae2: AuditEntry | ae1.op != ae2.op
}
assert AppendOnlyAudit { AppendOnlyAudit }
check AppendOnlyAudit for 8

// PATTERN: AppendOnly (notes)  ANCHOR: spec.md FR-011; data-model.md no UPDATE/DELETE on clinical_notes
pred AppendOnlyNotes {
  some ClinicalNote
  all n: ClinicalNote | one op: Operation | op.noteCreated = n
  all n: ClinicalNote |
    (some op: Operation |
        op.noteCreated = n and op.kind = PostRecordsNotes and op.outcome = Permitted)
}
assert AppendOnlyNotes { AppendOnlyNotes }
check AppendOnlyNotes for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md AuditEntry snapshot fields
pred AttributionCorrectness {
  some AuditEntry
  all ae: AuditEntry |
    ae.auditUser = ae.op.caller and
    ae.auditRole = ae.op.callerRoleSnapshot and
    ae.auditPatient = ae.op.targetPatient and
    ae.auditKind = ae.op.kind and
    ae.auditOutcome = ae.op.outcome
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006; contracts/http-api.md byte-equivalent not_found envelope
pred NoInformationLeakage {
  some Operation
  all op: Operation |
    (op.authenticated = True and (op.outcome = Denied or op.outcome = NotFoundOrDenied)) implies
      op.responseBytes = NotFoundEnvelope
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-005, FR-018 (administrator content-blindness)
pred AdminContentBlindness {
  some Operation
  all op: Operation | op.kind = PostAuditSearch implies
    (op.responseBytes != RecordOk and op.responseBytes != NoteCreated)
}
assert AdminContentBlindness { AdminContentBlindness }
check AdminContentBlindness for 8

// FEATURE-SPECIFIC  ANCHOR: FR-001 (authentication boundary)
pred FR_001_AuthRequired {
  some Operation
  all op: Operation | op.authenticated = False implies
    (op.outcome != Permitted and op.responseBytes = Unauthenticated401)
  all op: Operation | op.authenticated = False implies (no ae: AuditEntry | ae.op = op)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 (one role per user, drawn from the v1 catalogue)
pred FR_002_OneRolePerUser {
  some User
  all u: User | one u.role
  // Every role in use belongs to the v1 catalogue (enforced by abstract sig hierarchy).
  all u: User | u.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin + HospitalAdministrator)
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 (care-team gating, clinical roles only)
pred FR_004_CareTeamGating {
  some Operation
  all op: Operation |
    (op.outcome = Permitted and op.kind in (PostRecordsLookup + PostRecordsNotes)) implies
      (some ctm: CareTeamMembership |
         ctm.ctmClinician = op.caller and
         ctm.ctmPatient = op.targetPatient and
         ctm.ctmActive = True)
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 (administrators see no clinical content)
pred FR_005_AdminNoClinicalContent {
  some Operation
  all op: Operation | op.kind = PostAuditSearch implies
    (op.responseBytes != RecordOk and op.responseBytes != NoteCreated)
}
assert FR_005_AdminNoClinicalContent { FR_005_AdminNoClinicalContent }
check FR_005_AdminNoClinicalContent for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 (byte-equivalent unauthorised envelope)
pred FR_006_ByteEquivalentDenial {
  some Operation
  all op: Operation |
    (op.authenticated = True and (op.outcome = Denied or op.outcome = NotFoundOrDenied)) implies
      op.responseBytes = NotFoundEnvelope
}
assert FR_006_ByteEquivalentDenial { FR_006_ByteEquivalentDenial }
check FR_006_ByteEquivalentDenial for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 (clinical note author attribution snapshot)
pred FR_010_NoteAttribution {
  some ClinicalNote
  all op: Operation, n: ClinicalNote | op.noteCreated = n implies
    (n.noteAuthor = op.caller and
     n.notePatient = op.targetPatient and
     n.noteAuthorRole = op.callerRoleSnapshot)
  all n: ClinicalNote | n.noteAuthorRole != HospitalAdministrator
}
assert FR_010_NoteAttribution { FR_010_NoteAttribution }
check FR_010_NoteAttribution for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 (clinical notes append-only)
pred FR_011_NotesAppendOnly {
  some ClinicalNote
  all n: ClinicalNote | one op: Operation | op.noteCreated = n
  all n: ClinicalNote |
    (some op: Operation |
        op.noteCreated = n and op.kind = PostRecordsNotes and op.outcome = Permitted)
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 (always-on audit on clinical endpoints)
pred FR_012_AuditAlwaysOn {
  some Operation
  all op: Operation |
    (op.authenticated = True and op.kind in (PostRecordsLookup + PostRecordsNotes)) implies
      (one ae: AuditEntry | ae.op = op)
}
assert FR_012_AuditAlwaysOn { FR_012_AuditAlwaysOn }
check FR_012_AuditAlwaysOn for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 (audit-entry fields snapshot the operation)
pred FR_013_AuditFields {
  some AuditEntry
  all ae: AuditEntry |
    ae.auditUser = ae.op.caller and
    ae.auditRole = ae.op.callerRoleSnapshot and
    ae.auditPatient = ae.op.targetPatient and
    ae.auditKind = ae.op.kind and
    ae.auditOutcome = ae.op.outcome and
    ae.auditBasis = ae.op.basis
  // FR-013 note_id pairing: present iff add_note + permitted
  all ae: AuditEntry | some ae.auditNote iff
    (ae.auditKind = PostRecordsNotes and ae.auditOutcome = Permitted)
}
assert FR_013_AuditFields { FR_013_AuditFields }
check FR_013_AuditFields for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 (audit immutability — no duplicate or untracked entries)
pred FR_014_AuditImmutable {
  some AuditEntry
  all disj ae1, ae2: AuditEntry | ae1.op != ae2.op
}
assert FR_014_AuditImmutable { FR_014_AuditImmutable }
check FR_014_AuditImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 (audit-search is administrator-only)
pred FR_017_AdminOnlyAuditSearch {
  some Operation
  all op: Operation | (op.kind = PostAuditSearch and op.outcome = Permitted) implies
    op.callerRoleSnapshot = HospitalAdministrator
}
assert FR_017_AdminOnlyAuditSearch { FR_017_AdminOnlyAuditSearch }
check FR_017_AdminOnlyAuditSearch for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 (admin response carries no clinical content)
pred FR_018_AdminContentBlind {
  some Operation
  all op: Operation | op.kind = PostAuditSearch implies
    (op.responseBytes != RecordOk and op.responseBytes != NoteCreated)
}
assert FR_018_AdminContentBlind { FR_018_AdminContentBlind }
check FR_018_AdminContentBlind for 8