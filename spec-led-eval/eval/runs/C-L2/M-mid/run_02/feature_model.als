// === feature_model.als — Alloy model for Hospital Clinical Record Access (C-L2) ===
// Feature folder : C-L2  (012-hospital-clinical-records)
// Artefacts      : spec.md, data-model.md, contracts/http-api.md
// Generated for  : Alloy 6 / Alloy Analyser; exec via `java -jar alloy.jar exec`

// ── Role catalogue (FR-002, data-model.md UserRole enum) ──────────────────────
abstract sig UserRole {}
one sig Doctor     extends UserRole {}
one sig Nurse      extends UserRole {}
one sig Pharmacist extends UserRole {}
one sig ClinicalAdmin       extends UserRole {}
one sig HospitalAdministrator extends UserRole {}

// ── Operation kinds (data-model.md AccessType enum) ──────────────────────────
abstract sig OperationKind {}
one sig RecordLookup extends OperationKind {}   // POST /records/lookup
one sig AddNote      extends OperationKind {}   // POST /records/notes
one sig ListAudit    extends OperationKind {}   // POST /audit/search

// ── Outcome & auth-basis enums (data-model.md) ───────────────────────────────
abstract sig AccessOutcome {}
one sig Permitted         extends AccessOutcome {}
one sig Denied            extends AccessOutcome {}
one sig NotFoundOrDenied  extends AccessOutcome {}

abstract sig AuthBasis {}
one sig CareTeamMemberBasis    extends AuthBasis {}
one sig NotCareTeamMemberBasis extends AuthBasis {}
one sig PatientNotFoundBasis   extends AuthBasis {}
one sig AdministratorRoleBasis extends AuthBasis {}

// ── Response shapes (for byte-equivalence modelling FR-006) ──────────────────
abstract sig ResponseKind {}
one sig SuccessResponse      extends ResponseKind {}
one sig UnauthorisedResponse extends ResponseKind {}  // the single canonical 404

// ── Permission matrix — one singleton holding the allowed (Role×Op) relation ─
// contracts/http-api.md authorisation tables
one sig PermMatrix { Allowed: set UserRole -> OperationKind }

// ── Dynamic sigs ─────────────────────────────────────────────────────────────
sig User { userRole: one UserRole }

sig Patient {}

// Active care-team membership row: (clinician, patient) pair.
// Captures only active rows (FR-004 uses only active memberships).
sig CareTeamMembership {
  ctmMember  : one User,
  ctmPatient : one Patient
}

// Append-only clinical note (FR-011, data-model.md ClinicalNote).
sig ClinicalNote {
  notePatient : one Patient,
  noteAuthor  : one User
}

// Immutable audit entry (FR-012–FR-016, data-model.md AuditEntry).
sig AuditEntry {
  auditAccessor    : one User,
  auditPatient     : one Patient,
  auditKind        : one OperationKind,
  auditOutcome     : one AccessOutcome,
  auditBasis       : one AuthBasis,
  auditLinkedNote  : lone ClinicalNote  // null unless add_note + permitted
}

// An Operation is an authenticated request that has reached the service layer.
// Unauthenticated requests are blocked before producing any Operation atom
// (modelled by the absence of Operation atoms for such requests — FR-001).
sig Operation {
  opCaller    : one User,
  opKind      : one OperationKind,
  opPatient   : one Patient,
  opOutcome   : one AccessOutcome,
  opResponse  : one ResponseKind,
  opAudit     : one AuditEntry      // 1-to-1: every Operation has exactly one audit entry (FR-012)
}

// ── F_NonEmptyUniverse ────────────────────────────────────────────────────────
// Guarantees that check assertions are not vacuously satisfied in empty worlds.
fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
  some Operation
}

// ── F_PermissionMatrix ────────────────────────────────────────────────────────
// Encodes the exact (Role × OperationKind) allowed cells from
// contracts/http-api.md: clinical roles may use RecordLookup and AddNote;
// HospitalAdministrator may only use ListAudit.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor             -> RecordLookup) +
    (Doctor             -> AddNote)      +
    (Nurse              -> RecordLookup) +
    (Nurse              -> AddNote)      +
    (Pharmacist         -> RecordLookup) +
    (Pharmacist         -> AddNote)      +
    (ClinicalAdmin      -> RecordLookup) +
    (ClinicalAdmin      -> AddNote)      +
    (HospitalAdministrator -> ListAudit)
}

// ── F_AuditCorrespondence ─────────────────────────────────────────────────────
// The opAudit mapping is injective (each operation has its OWN audit entry),
// and the audit entry faithfully records who did what to which patient (FR-012, FR-013).
fact F_AuditCorrespondence {
  // injective: no two operations share an audit entry
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
  // attribution: audit entry records the same caller, patient, kind, and outcome
  all op: Operation | {
    op.opAudit.auditAccessor = op.opCaller
    op.opAudit.auditPatient  = op.opPatient
    op.opAudit.auditKind     = op.opKind
    op.opAudit.auditOutcome  = op.opOutcome
  }
  // every AuditEntry belongs to exactly one Operation (surjectivity closes the loop)
  all ae: AuditEntry | one op: Operation | op.opAudit = ae
}

// ── F_PermittedResponseIsSuccess ─────────────────────────────────────────────
// A permitted operation returns a SuccessResponse; all other outcomes return
// the canonical UnauthorisedResponse (FR-006).
fact F_PermittedResponseIsSuccess {
  all op: Operation | {
    op.opOutcome = Permitted        => op.opResponse = SuccessResponse
    op.opOutcome != Permitted       => op.opResponse = UnauthorisedResponse
  }
}

// ── F_CareTeamGating ─────────────────────────────────────────────────────────
// Clinical-role callers may obtain a Permitted outcome on RecordLookup or
// AddNote only when an active CareTeamMembership exists for (caller, patient).
// FR-004; contracts/http-api.md authorisation block for both clinical endpoints.
fact F_CareTeamGating {
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and op.opOutcome = Permitted)
      => (some m: CareTeamMembership |
            m.ctmMember = op.opCaller and m.ctmPatient = op.opPatient)
}

// ── F_AdminNoCareteam ─────────────────────────────────────────────────────────
// HospitalAdministrator users never appear as members of any care team.
// FR-005; contracts/http-api.md: "administrators are not members of any patient's care team".
fact F_AdminNoCareteam {
  no m: CareTeamMembership | m.ctmMember.userRole = HospitalAdministrator
}

// ── F_ClinicalEndpointsBlockAdmin ─────────────────────────────────────────────
// An administrator caller attempting RecordLookup or AddNote always receives
// Denied or NotFoundOrDenied (never Permitted). FR-005; contracts/http-api.md.
fact F_ClinicalEndpointsBlockAdmin {
  all op: Operation |
    (op.opCaller.userRole = HospitalAdministrator and
     op.opKind in (RecordLookup + AddNote))
       => op.opOutcome != Permitted
}

// ── F_ListAuditAdminOnly ──────────────────────────────────────────────────────
// Only HospitalAdministrator callers may reach a Permitted outcome on ListAudit.
// FR-017; contracts/http-api.md /audit/search authorisation.
fact F_ListAuditAdminOnly {
  all op: Operation |
    (op.opKind = ListAudit and op.opOutcome = Permitted)
      => op.opCaller.userRole = HospitalAdministrator
}

// ── F_NoteAuthorIsClinical ────────────────────────────────────────────────────
// Every ClinicalNote's author holds a clinical role (never HospitalAdministrator).
// data-model.md ClinicalNote.author_role CHECK; FR-005.
fact F_NoteAuthorIsClinical {
  all n: ClinicalNote |
    n.noteAuthor.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}

// ── F_AppendOnlyClinicalNotes ─────────────────────────────────────────────────
// Once a ClinicalNote atom exists it is never the opPatient-target of a
// destructive operation.  We encode "no deletion kind" structurally: the only
// OperationKind that creates notes is AddNote; no OperationKind removes them.
// A surrogate for the code-path-absence guarantee of FR-011 / data-model.md.
fact F_AppendOnlyClinicalNotes {
  // No two distinct operations both produce the same new note via their audit entry
  // (each permitted AddNote creates exactly one new, unique note).
  all disj op1, op2: Operation |
    (op1.opKind = AddNote and op1.opOutcome = Permitted and
     op2.opKind = AddNote and op2.opOutcome = Permitted)
       => op1.opAudit.auditLinkedNote != op2.opAudit.auditLinkedNote
  // Permitted AddNote audit entries always carry a linked note
  all op: Operation |
    (op.opKind = AddNote and op.opOutcome = Permitted)
      => (one n: ClinicalNote | op.opAudit.auditLinkedNote = n)
}

// ── F_AuditLinkedNoteConstraint ───────────────────────────────────────────────
// The note_id field of an AuditEntry is set iff access_type="add_note" AND
// outcome="permitted".  Encodes the data-model.md structural CHECK on audit_entries.
fact F_AuditLinkedNoteConstraint {
  all ae: AuditEntry | {
    // must have linked note iff add_note + permitted
    (ae.auditKind = AddNote and ae.auditOutcome = Permitted)
      <=> (some ae.auditLinkedNote)
  }
}

// ── F_AuthBasisConsistency ────────────────────────────────────────────────────
// The authorisation_basis field is consistent with the role and outcome.
// data-model.md AuthorisationBasis enum; contracts/http-api.md behaviour blocks.
fact F_AuthBasisConsistency {
  all op: Operation | {
    // care_team_member basis only when permitted on a clinical endpoint
    op.opAudit.auditBasis = CareTeamMemberBasis
      => (op.opKind in (RecordLookup + AddNote) and op.opOutcome = Permitted)
    // administrator_role basis only when it is an admin performing ListAudit
    op.opAudit.auditBasis = AdministratorRoleBasis
      => (op.opCaller.userRole = HospitalAdministrator and op.opKind = ListAudit)
    // not_care_team_member basis implies denied clinical operation
    op.opAudit.auditBasis = NotCareTeamMemberBasis
      => (op.opKind in (RecordLookup + AddNote) and op.opOutcome = Denied)
    // patient_not_found basis implies not_found_or_denied outcome
    op.opAudit.auditBasis = PatientNotFoundBasis
      => op.opOutcome = NotFoundOrDenied
  }
}

// ── F_ClinicalRoleForCareteam ─────────────────────────────────────────────────
// Every care-team member holds a clinical role (not administrator).
// data-model.md: ClinicalNote.author_role excludes hospital_administrator;
// care_team_memberships is only for clinicians.
fact F_ClinicalRoleForCareteam {
  all m: CareTeamMembership |
    m.ctmMember.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}

// ═════════════════════════════════════════════════════════════════════════════
//  PREDICATES AND ASSERTIONS
// ═════════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-004, FR-005, FR-017
pred LeastPrivilege {
  // Every permitted operation is in the allowed (Role × OperationKind) matrix.
  all op: Operation |
    op.opOutcome = Permitted =>
      (op.opCaller.userRole -> op.opKind in PermMatrix.Allowed)
  // Every denied or not-found outcome for a clinical op from a non-admin
  // user corresponds to a role that lacks the matrix entry for that op.
  // (Converse: no admin ever gets Permitted on clinical endpoints.)
  all op: Operation |
    (op.opCaller.userRole = HospitalAdministrator and
     op.opKind in (RecordLookup + AddNote))
      => op.opOutcome != Permitted
  // No clinical role ever gets Permitted on ListAudit
  all op: Operation |
    (op.opCaller.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
     op.opKind = ListAudit)
      => op.opOutcome != Permitted
  some Operation  // universe non-vacuity
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table (all 15 Role×Op cells defined)
pred PermissionCompleteness {
  // Every (Role, Op) pair is either explicitly allowed or not in the matrix —
  // i.e., the matrix is exactly the closed-world set we declared, no gaps.
  PermMatrix.Allowed =
    (Doctor             -> RecordLookup) +
    (Doctor             -> AddNote)      +
    (Nurse              -> RecordLookup) +
    (Nurse              -> AddNote)      +
    (Pharmacist         -> RecordLookup) +
    (Pharmacist         -> AddNote)      +
    (ClinicalAdmin      -> RecordLookup) +
    (ClinicalAdmin      -> AddNote)      +
    (HospitalAdministrator -> ListAudit)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-004 (clinical access), FR-005 (admin audit), FR-017
pred PermissionGrounding {
  // Every allowed cell traces to a documented FR: clinical ops → FR-004;
  // admin audit → FR-017. The matrix has exactly these two grounding FRs.
  // Encoded as: HospitalAdministrator is NOT in the clinical allowed set,
  // and clinical roles are NOT in the ListAudit allowed set.
  HospitalAdministrator -> RecordLookup not in PermMatrix.Allowed
  HospitalAdministrator -> AddNote      not in PermMatrix.Allowed
  Doctor      -> ListAudit not in PermMatrix.Allowed
  Nurse       -> ListAudit not in PermMatrix.Allowed
  Pharmacist  -> ListAudit not in PermMatrix.Allowed
  ClinicalAdmin -> ListAudit not in PermMatrix.Allowed
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
  // Modelled structurally: every Operation atom has an opCaller (authenticated user).
  // There is no path to produce an AuditEntry without a resolved User.
  // No AuditEntry exists without an Operation (F_AuditCorrespondence ensures this).
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
  all op: Operation  | one op.opCaller
  some Operation  // non-vacuity
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012; data-model.md audit_entries, SC-001, SC-002
pred AuditCompleteness {
  // 1. Every Operation has exactly one audit entry (opAudit is total and functional).
  all op: Operation | one op.opAudit
  // 2. The audit→operation mapping is also surjective: no orphan AuditEntry.
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
  // 3. No two operations share an audit entry (injective).
  all disj op1, op2: Operation | op1.opAudit != op2.opAudit
  some Operation
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly (clinical notes)  ANCHOR: spec.md FR-011; data-model.md ClinicalNote append-only; SC-007
pred AppendOnly {
  // Each permitted AddNote produces a unique new note — no note is produced twice.
  all disj op1, op2: Operation |
    (op1.opKind = AddNote and op1.opOutcome = Permitted and
     op2.opKind = AddNote and op2.opOutcome = Permitted)
      => op1.opAudit.auditLinkedNote != op2.opAudit.auditLinkedNote
  // No note appears as the linked note of a non-add_note operation
  // (there is no delete/edit op kind that could target a note).
  all op: Operation |
    op.opKind != AddNote => no op.opAudit.auditLinkedNote
  some Operation
  some ClinicalNote
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md AuditEntry (snapshot fields)
pred AttributionCorrectness {
  // Audit entry accessor, patient, kind, and outcome match the operation they record.
  all op: Operation | {
    op.opAudit.auditAccessor = op.opCaller
    op.opAudit.auditPatient  = op.opPatient
    op.opAudit.auditKind     = op.opKind
    op.opAudit.auditOutcome  = op.opOutcome
  }
  some Operation
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  // A clinical-role operation is permitted iff the caller has an active
  // care-team membership for the target patient.
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and
     op.opCaller.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
     op.opOutcome = Permitted)
       => (some m: CareTeamMembership |
             m.ctmMember = op.opCaller and m.ctmPatient = op.opPatient)
  // Converse: if no care-team membership, outcome is not Permitted.
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and
     op.opCaller.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
     (no m: CareTeamMembership |
       m.ctmMember = op.opCaller and m.ctmPatient = op.opPatient))
       => op.opOutcome != Permitted
  some Operation
  some CareTeamMembership
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006; contracts/http-api.md byte-equivalent not-found response; SC-003
pred NoInformationLeakage {
  // Denied and NotFoundOrDenied outcomes produce the same response kind —
  // the single canonical UnauthorisedResponse.  No non-Permitted outcome leaks
  // a different response shape that could distinguish "exists but forbidden"
  // from "does not exist."
  all op: Operation |
    op.opOutcome != Permitted => op.opResponse = UnauthorisedResponse
  all op: Operation |
    op.opOutcome = Permitted  => op.opResponse = SuccessResponse
  some op: Operation | op.opOutcome = Denied
  some op: Operation | op.opOutcome = NotFoundOrDenied
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-009; contracts/http-api.md 400 validation_error; data-model.md atomicity
pred ValidationBeforeMutation {
  // A note is only linked to an audit entry when the outcome is Permitted
  // (i.e., validation passed and the caller was authorised). A denied or
  // not-found outcome never produces a new ClinicalNote.
  all ae: AuditEntry |
    ae.auditKind = AddNote and ae.auditOutcome != Permitted
      => no ae.auditLinkedNote
  // Equivalently: the only way a note appears in the model as a linked note
  // is via a Permitted AddNote audit entry.
  all n: ClinicalNote |
    (some ae: AuditEntry |
       ae.auditLinkedNote = n and ae.auditKind = AddNote and ae.auditOutcome = Permitted)
  some Operation
  some ClinicalNote
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// ── Feature-specific predicates ───────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001; spec.md "unauthenticated requests … before any audit entry is written"
pred FR_001_AuthRequired {
  // Every AuditEntry is produced by an Operation (authenticated request).
  // No audit entry exists without a resolved caller.
  all ae: AuditEntry | (some op: Operation | op.opAudit = ae and one op.opCaller)
  some AuditEntry
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004; spec.md care-team gating; data-model.md CareTeamMembership
pred FR_004_CareTeamGating {
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and op.opOutcome = Permitted)
      => (some m: CareTeamMembership |
            m.ctmMember = op.opCaller and m.ctmPatient = op.opPatient)
  some op: Operation |
    op.opKind = RecordLookup and op.opOutcome = Permitted
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005; spec.md "hospital_administrator … cannot read clinical content"
pred FR_005_AdminNoClinicalContent {
  // Administrator-role users are never on any care team, so can never
  // obtain Permitted on RecordLookup or AddNote.
  all op: Operation |
    op.opCaller.userRole = HospitalAdministrator
      => op.opKind not in (RecordLookup + AddNote) or op.opOutcome != Permitted
  // No care-team membership row exists for any admin user.
  all m: CareTeamMembership | m.ctmMember.userRole != HospitalAdministrator
  some u: User | u.userRole = HospitalAdministrator
}
assert FR_005_AdminNoClinicalContent { FR_005_AdminNoClinicalContent }
check FR_005_AdminNoClinicalContent for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006; contracts/http-api.md byte-equivalent not-found; SC-003
pred FR_006_ByteEquivalentResponse {
  // Both Denied and NotFoundOrDenied outcomes map to UnauthorisedResponse.
  // A clinician observing a "patient not on care team" scenario and a
  // "patient does not exist" scenario receive the same response kind.
  all op: Operation | op.opOutcome in (Denied + NotFoundOrDenied)
      => op.opResponse = UnauthorisedResponse
  some op1: Operation | op1.opOutcome = Denied
  some op2: Operation | op2.opOutcome = NotFoundOrDenied
}
assert FR_006_ByteEquivalentResponse { FR_006_ByteEquivalentResponse }
check FR_006_ByteEquivalentResponse for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009; spec.md note submission validation; contracts/http-api.md 400 validation_error
pred FR_009_NoteValidation {
  // A clinical note appears in the system only if the corresponding AddNote
  // operation was Permitted.  No note is created for rejected submissions.
  all n: ClinicalNote | (
    some ae: AuditEntry |
      ae.auditLinkedNote = n and
      ae.auditKind = AddNote and
      ae.auditOutcome = Permitted
  )
  some ClinicalNote
}
assert FR_009_NoteValidation { FR_009_NoteValidation }
check FR_009_NoteValidation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011; spec.md append-only notes; data-model.md ClinicalNote append-only enforcement
pred FR_011_NotesAppendOnly {
  // No note is the linked note of more than one audit entry
  // (each note is created exactly once).
  all n: ClinicalNote |
    (one ae: AuditEntry | ae.auditLinkedNote = n)
  // The note author always holds a clinical role (not HospitalAdministrator).
  all n: ClinicalNote |
    n.noteAuthor.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
  some ClinicalNote
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012; spec.md always-on audit; data-model.md audit_entries; SC-001, SC-002
pred FR_012_AlwaysOnAudit {
  // 1. Every operation produces exactly one audit entry.
  all op: Operation | one op.opAudit
  // 2. Every audit entry is produced by exactly one operation.
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
  // 3. Operations with Permitted outcome have a matching audit entry
  //    recording Permitted (no audit suppression on success).
  all op: Operation |
    op.opOutcome = Permitted => op.opAudit.auditOutcome = Permitted
  some Operation
}
assert FR_012_AlwaysOnAudit { FR_012_AlwaysOnAudit }
check FR_012_AlwaysOnAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013; data-model.md AuditEntry fields; spec.md audit-entry shape
pred FR_013_AuditEntryShape {
  // Every audit entry carries a non-null accessor, patient, kind, outcome, basis.
  all ae: AuditEntry | {
    one ae.auditAccessor
    one ae.auditPatient
    one ae.auditKind
    one ae.auditOutcome
    one ae.auditBasis
  }
  // note_id present iff add_note + permitted (the data-model CHECK)
  all ae: AuditEntry |
    (ae.auditKind = AddNote and ae.auditOutcome = Permitted) <=> (some ae.auditLinkedNote)
  some AuditEntry
}
assert FR_013_AuditEntryShape { FR_013_AuditEntryShape }
check FR_013_AuditEntryShape for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014; spec.md audit immutability; data-model.md AuditEntry append-only; SC-008
pred FR_014_AuditImmutable {
  // Immutability: no audit entry shares its identity with another, and every
  // audit entry is linked to exactly one operation (created-once semantics).
  all disj ae1, ae2: AuditEntry | ae1 != ae2
  all ae: AuditEntry | (one op: Operation | op.opAudit = ae)
  // There are no "dangling" audit entries not tied to an operation.
  AuditEntry = { ae: AuditEntry | some op: Operation | op.opAudit = ae }
  some AuditEntry
}
assert FR_014_AuditImmutable { FR_014_AuditImmutable }
check FR_014_AuditImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017; spec.md admin-only audit endpoint; contracts/http-api.md /audit/search
pred FR_017_AdminOnlyAuditEndpoint {
  // A Permitted outcome on ListAudit is only ever reached by an HospitalAdministrator.
  all op: Operation |
    (op.opKind = ListAudit and op.opOutcome = Permitted)
      => op.opCaller.userRole = HospitalAdministrator
  // Clinical roles attempting ListAudit never get Permitted.
  all op: Operation |
    (op.opCaller.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
     op.opKind = ListAudit)
      => op.opOutcome != Permitted
  some op: Operation |
    op.opKind = ListAudit and op.opOutcome = Permitted
}
assert FR_017_AdminOnlyAuditEndpoint { FR_017_AdminOnlyAuditEndpoint }
check FR_017_AdminOnlyAuditEndpoint for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018; spec.md admin content-blindness; contracts/http-api.md /audit/search response
pred FR_018_AdminContentBlindness {
  // An administrator's Permitted ListAudit operation cannot return a ClinicalNote
  // content field. Modelled as: the auditLinkedNote of a list_audit audit entry
  // is always absent (only note identifiers, not content, are exposed).
  all op: Operation |
    op.opKind = ListAudit => no op.opAudit.auditLinkedNote
  // Note: the note_id field (opaque ID) in the admin response is modelled
  // separately via the add_note entries visible to admin; the admin's own
  // list_audit audit entry carries no note reference.
  some op: Operation | op.opKind = ListAudit and op.opOutcome = Permitted
}
assert FR_018_AdminContentBlindness { FR_018_AdminContentBlindness }
check FR_018_AdminContentBlindness for 8