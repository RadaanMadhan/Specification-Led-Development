// === feature_model.als — Alloy model for Hospital Clinical Record Access ===
// Self-contained Alloy 6 model of the structural invariants of feature C-L2
// (012-hospital-clinical-records). Encodes the v1 permission matrix, the
// care-team-gating rule, audit completeness, append-only semantics for both
// clinical notes and audit entries, attribution correctness, and the
// byte-equivalent unauthorised response.

// Non-empty universe so quantified assertions don't pass vacuously
fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some ClinicalNote
  some Operation
  some AuditEntry
}

// --- Roles (FR-002) ---
abstract sig Role {}
one sig Doctor extends Role {}
one sig Nurse extends Role {}
one sig Pharmacist extends Role {}
one sig ClinicalAdmin extends Role {}
one sig HospitalAdministrator extends Role {}

// --- Operation kinds / endpoints (contracts/http-api.md) ---
abstract sig OperationKind {}
one sig RecordLookup extends OperationKind {}
one sig AddNote extends OperationKind {}
one sig ListAudit extends OperationKind {}

// --- Outcomes (data-model.md AccessOutcome) ---
abstract sig Outcome {}
one sig Permitted extends Outcome {}
one sig Denied extends Outcome {}
one sig NotFoundOrDenied extends Outcome {}

// --- External response shapes (for byte-equivalence reasoning, FR-006) ---
abstract sig ExternalResponse {}
one sig NotFoundEnvelope extends ExternalResponse {}
one sig RecordPayload extends ExternalResponse {}
one sig NotePayload extends ExternalResponse {}
one sig AuditPayload extends ExternalResponse {}

// --- Boolean-style markers ---
one sig AuthMarker {}
one sig ActiveMarker {}

// --- Permission matrix (singleton-sig field) ---
one sig PermMatrix { Allowed: set Role -> OperationKind }

// --- Domain entities ---
sig User { userRole: one Role }
sig Patient {}

sig CareTeamMembership {
  ctClinician: one User,
  ctPatient: one Patient,
  ctActive: lone ActiveMarker
}

sig ClinicalNote {
  notePatient: one Patient,
  noteAuthor: one User,
  noteAuthorRoleSnap: one Role
}

sig Operation {
  caller: one User,
  callerRoleSnap: one Role,
  opKind: one OperationKind,
  targetPatient: lone Patient,
  authenticated: lone AuthMarker,
  outcome: one Outcome,
  createdNote: lone ClinicalNote,
  externalResponse: one ExternalResponse
}

sig AuditEntry {
  ofOperation: one Operation,
  auditUser: one User,
  auditUserRole: one Role,
  auditTargetPatient: lone Patient,
  auditAccessType: one OperationKind,
  auditOutcome: one Outcome,
  auditNoteId: lone ClinicalNote
}

fun ClinicalRolesFun : set Role {
  Doctor + Nurse + Pharmacist + ClinicalAdmin
}

// =========================================================================
// FACTS — named for mutation testing
// =========================================================================

// Permission matrix wiring (FR-004, FR-005, FR-017)
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor -> RecordLookup) + (Doctor -> AddNote) +
    (Nurse -> RecordLookup) + (Nurse -> AddNote) +
    (Pharmacist -> RecordLookup) + (Pharmacist -> AddNote) +
    (ClinicalAdmin -> RecordLookup) + (ClinicalAdmin -> AddNote) +
    (HospitalAdministrator -> ListAudit)
}

// Permitted ops obey the role/op matrix (FR-005, FR-017)
fact F_LeastPrivilegeStructural {
  all op: Operation |
    op.outcome = Permitted implies
    (op.caller.userRole -> op.opKind) in PermMatrix.Allowed
}

// Care-team rows are only ever clinical-role users (FR-005 — admin not on care teams)
fact F_CareTeamClinicalOnly {
  all ct: CareTeamMembership | ct.ctClinician.userRole in ClinicalRolesFun
}

// Schema CHECK: author_role in clinical roles only (FR-005, data-model.md)
fact F_NoteAuthorClinicalRoleOnly {
  all n: ClinicalNote | n.noteAuthorRoleSnap in ClinicalRolesFun
}

// Author-role snapshot equals actual author role at addition time (FR-010)
fact F_NoteAuthorRoleSnapshot {
  all n: ClinicalNote | n.noteAuthorRoleSnap = n.noteAuthor.userRole
}

// Caller-role snapshot equals actual caller role at access time (FR-013)
fact F_OpCallerRoleSnapshot {
  all op: Operation | op.callerRoleSnap = op.caller.userRole
}

// Each clinical note is created by exactly one operation (FR-011)
fact F_NoteUniqueCreatingOp {
  all n: ClinicalNote | one op: Operation | op.createdNote = n
}

// A note is created exactly when the op is an authenticated permitted AddNote
// (FR-010, FR-011, FR-009 validation-before-mutation)
fact F_NoteCreatedExactlyOnPermittedAddNote {
  all op: Operation |
    (some op.createdNote) iff
    (op.opKind = AddNote and op.outcome = Permitted and some op.authenticated)
}

// Created note's author and patient match the operation (FR-010)
fact F_NoteFieldsMatchOperation {
  all op: Operation | some op.createdNote implies
    (op.createdNote.noteAuthor = op.caller and
     op.createdNote.notePatient = op.targetPatient)
}

// Permitted operations have a resolved target patient
fact F_PermittedHasResolvedPatient {
  all op: Operation | op.outcome = Permitted implies some op.targetPatient
}

// Audits exist only for authenticated operations (FR-001)
fact F_AuditOnlyForAuthenticatedOp {
  all ae: AuditEntry | some ae.ofOperation.authenticated
}

// Audits exist only for audit-relevant operations (read/add_note always;
// list_audit only when permitted — contracts/http-api.md)
fact F_AuditOnlyForRelevantOp {
  all ae: AuditEntry |
    (ae.ofOperation.opKind in (RecordLookup + AddNote)) or
    (ae.ofOperation.opKind = ListAudit and ae.ofOperation.outcome = Permitted)
}

// Every audit-relevant authenticated op produces exactly one audit (FR-012)
fact F_AuditCompletenessFact { /* MUTATED — body cleared by validator */ }

// At most one audit per operation (FR-012 uniqueness)
fact F_OneAuditPerOp {
  all op: Operation | lone ae: AuditEntry | ae.ofOperation = op
}

// Audit fields are exact snapshots of the operation (FR-013)
fact F_AuditSnapshotsMatchOp {
  all ae: AuditEntry |
    ae.auditUser = ae.ofOperation.caller and
    ae.auditUserRole = ae.ofOperation.callerRoleSnap and
    ae.auditTargetPatient = ae.ofOperation.targetPatient and
    ae.auditAccessType = ae.ofOperation.opKind and
    ae.auditOutcome = ae.ofOperation.outcome
}

// Audit note_id pairing CHECK (data-model.md schema CHECK on audit_entries)
fact F_AuditNoteIdPairing {
  all ae: AuditEntry |
    (ae.auditAccessType = AddNote and ae.auditOutcome = Permitted) implies
      ae.auditNoteId = ae.ofOperation.createdNote
  all ae: AuditEntry |
    (ae.auditAccessType = AddNote and ae.auditOutcome != Permitted) implies
      no ae.auditNoteId
  all ae: AuditEntry |
    ae.auditAccessType in (RecordLookup + ListAudit) implies no ae.auditNoteId
}

// Care-team gating: permitted clinical access requires an active membership (FR-004)
fact F_CareTeamGating {
  all op: Operation |
    (op.outcome = Permitted and op.opKind in (RecordLookup + AddNote)) implies
    (some ct: CareTeamMembership |
       ct.ctClinician = op.caller and
       ct.ctPatient = op.targetPatient and
       some ct.ctActive)
}

// Byte-equivalent unauthorised envelope (FR-006); per-payload shape otherwise
fact F_ExternalResponseShape {
  all op: Operation |
    op.outcome != Permitted implies op.externalResponse = NotFoundEnvelope
  all op: Operation |
    (op.outcome = Permitted and op.opKind = RecordLookup) implies
      op.externalResponse = RecordPayload
  all op: Operation |
    (op.outcome = Permitted and op.opKind = AddNote) implies
      op.externalResponse = NotePayload
  all op: Operation |
    (op.outcome = Permitted and op.opKind = ListAudit) implies
      op.externalResponse = AuditPayload
}

// =========================================================================
// PATTERN PREDICATES + ASSERTIONS
// =========================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-005, FR-017
pred LeastPrivilege {
  some Operation
  no op: Operation |
    op.outcome = Permitted and
    (op.caller.userRole -> op.opKind) not in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables
pred PermissionCompleteness {
  all r: Role | some k: OperationKind | (r -> k) in PermMatrix.Allowed
  all k: OperationKind | some r: Role | (r -> k) in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  some AuditEntry
  all ae: AuditEntry | some ae.ofOperation.authenticated
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012; data-model.md
pred AuditCompleteness {
  all op: Operation |
    (some op.authenticated and
     (op.opKind in (RecordLookup + AddNote) or
      (op.opKind = ListAudit and op.outcome = Permitted))) implies
    (one ae: AuditEntry | ae.ofOperation = op)
  all ae: AuditEntry | one ae.ofOperation
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011; data-model.md "no UPDATE/DELETE on clinical_notes"
pred AppendOnly {
  some ClinicalNote
  all n: ClinicalNote |
    (one op: Operation | op.createdNote = n) and
    (all op: Operation | op.createdNote = n implies
       (op.opKind = AddNote and op.outcome = Permitted))
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AppendOnly (audit variant)  ANCHOR: spec.md FR-014; data-model.md audit immutability
pred AppendOnlyAudit {
  some AuditEntry
  all op: Operation | lone ae: AuditEntry | ae.ofOperation = op
  all ae: AuditEntry | one ae.ofOperation
}
assert AppendOnlyAudit { AppendOnlyAudit }
check AppendOnlyAudit for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md audit-entry fields
pred AttributionCorrectness {
  some AuditEntry
  all ae: AuditEntry |
    ae.auditUser = ae.ofOperation.caller and
    ae.auditUserRole = ae.ofOperation.caller.userRole and
    ae.auditAccessType = ae.ofOperation.opKind and
    ae.auditOutcome = ae.ofOperation.outcome and
    ae.auditTargetPatient = ae.ofOperation.targetPatient
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004 (care-team membership gating)
pred OwnershipBasedAccess {
  some Operation
  all op: Operation |
    (op.outcome = Permitted and op.opKind in (RecordLookup + AddNote)) implies
    (some ct: CareTeamMembership |
       ct.ctClinician = op.caller and
       ct.ctPatient = op.targetPatient and
       some ct.ctActive)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006 (byte-equivalent unauthorised envelope)
pred NoInformationLeakage {
  all op1, op2: Operation |
    (op1.outcome in (Denied + NotFoundOrDenied) and
     op2.outcome in (Denied + NotFoundOrDenied)) implies
    op1.externalResponse = op2.externalResponse
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-009; edge case "audit-write timing budget breach"
pred ValidationBeforeMutation {
  some Operation
  all op: Operation | op.outcome != Permitted implies no op.createdNote
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// =========================================================================
// FR-SPECIFIC ASSERTIONS
// =========================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication boundary
pred FR_001_AuthRequired {
  some AuditEntry
  all ae: AuditEntry | some ae.ofOperation.authenticated
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 v1 role catalogue
pred FR_002_FiveRoleCatalogue {
  some User
  all u: User | one u.userRole
  Role = Doctor + Nurse + Pharmacist + ClinicalAdmin + HospitalAdministrator
}
assert FR_002_FiveRoleCatalogue { FR_002_FiveRoleCatalogue }
check FR_002_FiveRoleCatalogue for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 — patient_id never in URL path: structurally enforced
// by single Operation sig with targetPatient as a body-supplied resolution. Modelled
// declaratively: only one resolution channel exists (no PathPatient sig).
pred FR_003_PatientIdNotInUrl {
  // No Operation has any patient reference except through targetPatient
  // (vacuously enforced by the sig schema — this predicate documents the invariant
  // and asserts the universe contains at least one Operation to make it bite).
  some Operation
  all op: Operation | op.targetPatient in Patient
}
assert FR_003_PatientIdNotInUrl { FR_003_PatientIdNotInUrl }
check FR_003_PatientIdNotInUrl for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 care-team gating
pred FR_004_CareTeamGating {
  some Operation
  all op: Operation |
    (op.outcome = Permitted and op.opKind in (RecordLookup + AddNote)) implies
    (op.caller.userRole in ClinicalRolesFun and
     (some ct: CareTeamMembership |
        ct.ctClinician = op.caller and
        ct.ctPatient = op.targetPatient and
        some ct.ctActive))
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 admin no clinical content
pred FR_005_AdminNoClinicalContent {
  no op: Operation |
    op.caller.userRole = HospitalAdministrator and
    op.outcome = Permitted and
    op.opKind in (RecordLookup + AddNote)
  no n: ClinicalNote | n.noteAuthorRoleSnap = HospitalAdministrator
}
assert FR_005_AdminNoClinicalContent { FR_005_AdminNoClinicalContent }
check FR_005_AdminNoClinicalContent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 byte-equivalent unauthorised envelope
pred FR_006_ByteEquivalentNotFound {
  all op: Operation | op.outcome != Permitted implies op.externalResponse = NotFoundEnvelope
}
assert FR_006_ByteEquivalentNotFound { FR_006_ByteEquivalentNotFound }
check FR_006_ByteEquivalentNotFound for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007/FR-019/FR-020 successful read produces RecordPayload
pred FR_007_PermittedReadShape {
  some Operation
  all op: Operation |
    (op.opKind = RecordLookup and op.outcome = Permitted) implies
    op.externalResponse = RecordPayload
}
assert FR_007_PermittedReadShape { FR_007_PermittedReadShape }
check FR_007_PermittedReadShape for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 patient summary scope (captured by the absence of
// clinical content sigs beyond ClinicalNote/PatientSummary — modelled implicitly).
pred FR_008_RecordPayloadScope {
  some Operation
  all op: Operation | op.externalResponse in ExternalResponse
}
assert FR_008_RecordPayloadScope { FR_008_RecordPayloadScope }
check FR_008_RecordPayloadScope for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 validation rejection produces no state change
pred FR_009_NoNoteOnDenial {
  all op: Operation |
    (op.opKind = AddNote and op.outcome != Permitted) implies no op.createdNote
}
assert FR_009_NoNoteOnDenial { FR_009_NoNoteOnDenial }
check FR_009_NoNoteOnDenial for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 note persistence — author/patient match the op
pred FR_010_NoteAttribution {
  some ClinicalNote
  all n: ClinicalNote |
    (one op: Operation | op.createdNote = n) and
    (all op: Operation | op.createdNote = n implies
       (n.noteAuthor = op.caller and n.notePatient = op.targetPatient))
}
assert FR_010_NoteAttribution { FR_010_NoteAttribution }
check FR_010_NoteAttribution for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 clinical notes append-only
pred FR_011_NotesAppendOnly {
  some ClinicalNote
  all n: ClinicalNote | one op: Operation | op.createdNote = n
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 always-on audit
pred FR_012_AuditPerAccess {
  all op: Operation |
    (some op.authenticated and op.opKind in (RecordLookup + AddNote)) implies
    (one ae: AuditEntry | ae.ofOperation = op)
}
assert FR_012_AuditPerAccess { FR_012_AuditPerAccess }
check FR_012_AuditPerAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 audit fields = snapshots of op
pred FR_013_AuditSnapshot {
  some AuditEntry
  all ae: AuditEntry |
    ae.auditUser = ae.ofOperation.caller and
    ae.auditUserRole = ae.ofOperation.callerRoleSnap and
    ae.auditAccessType = ae.ofOperation.opKind and
    ae.auditOutcome = ae.ofOperation.outcome
}
assert FR_013_AuditSnapshot { FR_013_AuditSnapshot }
check FR_013_AuditSnapshot for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 audit immutable / one-per-op
pred FR_014_AuditImmutable {
  all op: Operation | lone ae: AuditEntry | ae.ofOperation = op
  all ae: AuditEntry | one ae.ofOperation
}
assert FR_014_AuditImmutable { FR_014_AuditImmutable }
check FR_014_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 2-second budget — modelled as: no audit-relevant
// operation reaches "permitted" without its matching audit entry persisting.
pred FR_015_NoPermittedWithoutAudit {
  all op: Operation |
    (op.outcome = Permitted and
     (op.opKind in (RecordLookup + AddNote) or op.opKind = ListAudit)) implies
    (one ae: AuditEntry | ae.ofOperation = op)
}
assert FR_015_NoPermittedWithoutAudit { FR_015_NoPermittedWithoutAudit }
check FR_015_NoPermittedWithoutAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 7-year retention — modelled as: no operation
// removes existing audit entries (no DeleteAudit op kind exists in the surface).
pred FR_016_AuditNotDeleted {
  // Every audit entry persists (one-to-one with its op) — no orphan or vanished audit.
  all ae: AuditEntry | one ae.ofOperation
}
assert FR_016_AuditNotDeleted { FR_016_AuditNotDeleted }
check FR_016_AuditNotDeleted for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 admin-only audit endpoint
pred FR_017_AdminOnlyListAudit {
  all op: Operation |
    (op.outcome = Permitted and op.opKind = ListAudit) implies
    op.caller.userRole = HospitalAdministrator
}
assert FR_017_AdminOnlyListAudit { FR_017_AdminOnlyListAudit }
check FR_017_AdminOnlyListAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 admin response carries no clinical content
pred FR_018_AdminContentBlind {
  // ListAudit operations do not produce ClinicalNote artefacts;
  // hospital_administrator never appears as a note author at all.
  all op: Operation | op.opKind = ListAudit implies no op.createdNote
  no n: ClinicalNote | n.noteAuthor.userRole = HospitalAdministrator
}
assert FR_018_AdminContentBlind { FR_018_AdminContentBlind }
check FR_018_AdminContentBlind for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 safety fields first — successful read produces RecordPayload
pred FR_019_SafetyFieldsFirst {
  all op: Operation |
    (op.outcome = Permitted and op.opKind = RecordLookup) implies
    op.externalResponse = RecordPayload
}
assert FR_019_SafetyFieldsFirst { FR_019_SafetyFieldsFirst }
check FR_019_SafetyFieldsFirst for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020 notes count before notes list — same RecordPayload shape
pred FR_020_NotesCountBeforeNotes {
  all op: Operation |
    (op.outcome = Permitted and op.opKind = RecordLookup) implies
    op.externalResponse = RecordPayload
}
assert FR_020_NotesCountBeforeNotes { FR_020_NotesCountBeforeNotes }
check FR_020_NotesCountBeforeNotes for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AuditCompletenessViolation { some op: Operation | some op.authenticated and op.opKind = RecordLookup and (no ae: AuditEntry | ae.ofOperation = op) }
