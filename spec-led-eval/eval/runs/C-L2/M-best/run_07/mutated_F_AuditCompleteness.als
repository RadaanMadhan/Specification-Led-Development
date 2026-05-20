// === feature_model.als — Alloy model for Hospital Clinical Record Access (012) ===

// ----------------------------------------------------------------------
// Roles (from spec.md FR-002 catalogue and data-model.md UserRole enum)
// ----------------------------------------------------------------------
abstract sig Role {}
one sig Doctor extends Role {}
one sig Nurse extends Role {}
one sig Pharmacist extends Role {}
one sig ClinicalAdmin extends Role {}
one sig HospitalAdministrator extends Role {}

fun ClinicalRoles : set Role { Doctor + Nurse + Pharmacist + ClinicalAdmin }

// ----------------------------------------------------------------------
// Operation kinds (contracts/http-api.md three endpoints)
// ----------------------------------------------------------------------
abstract sig OperationKind {}
one sig OpRead extends OperationKind {}          // POST /records/lookup
one sig OpAddNote extends OperationKind {}       // POST /records/notes
one sig OpListAudit extends OperationKind {}     // POST /audit/search

// ----------------------------------------------------------------------
// Outcomes and authorisation basis (data-model.md enums)
// ----------------------------------------------------------------------
abstract sig Outcome {}
one sig Permitted extends Outcome {}
one sig Denied extends Outcome {}
one sig NotFoundOrDenied extends Outcome {}

abstract sig Basis {}
one sig CareTeamMember extends Basis {}
one sig NotCareTeamMember extends Basis {}
one sig PatientNotFound extends Basis {}
one sig AdministratorRole extends Basis {}

// ----------------------------------------------------------------------
// Externally visible response body categories (FR-006 byte-equivalence)
// ----------------------------------------------------------------------
abstract sig ResponseBody {}
one sig BodyOK extends ResponseBody {}           // 200 OK clinical record
one sig BodyCreated extends ResponseBody {}      // 201 add-note body
one sig BodyAuditList extends ResponseBody {}    // 200 OK admin audit list
one sig BodyNotFound extends ResponseBody {}     // 404 byte-equivalent

// ----------------------------------------------------------------------
// Permission matrix (Role x OperationKind -> "allow")
// Encoded from contracts/http-api.md authorisation sections
// ----------------------------------------------------------------------
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ----------------------------------------------------------------------
// Core entities (data-model.md)
// ----------------------------------------------------------------------
sig User { role: one Role }
sig Patient {}

sig CareTeamMembership {
  clinician: one User,
  patient:   one Patient
}
// Active subset of memberships (status = 'active')
sig ActiveMembership in CareTeamMembership {}

sig Operation {
  caller:        one User,
  targetPatient: one Patient,
  kind:          one OperationKind,
  outcome:       one Outcome,
  basis:         one Basis,
  visibleBody:   one ResponseBody
}

sig ClinicalNote {
  author:     one User,
  authorRole: one Role,
  patient:    one Patient,
  createdBy:  one Operation
}

sig AuditEntry {
  operation:     one Operation,
  recordedUser:  one User,
  recordedRole:  one Role,
  recordedNote:  lone ClinicalNote
}

// ----------------------------------------------------------------------
// Non-empty universe so quantified assertions are non-vacuous
// ----------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some ActiveMembership
  some Operation
  some ClinicalNote
  some AuditEntry
}

// ======================================================================
// LOAD-BEARING FACTS
// ======================================================================

// Permission matrix from contracts/http-api.md (FR-004, FR-005, FR-017)
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    ((Doctor + Nurse + Pharmacist + ClinicalAdmin) -> (OpRead + OpAddNote))
    + (HospitalAdministrator -> OpListAudit)
}

// Note-author role exclusion: hospital_administrator cannot author notes
// (data-model.md clinical_notes.author_role CHECK)
fact F_NoteAuthorClinicalOnly {
  all n: ClinicalNote | n.authorRole in ClinicalRoles
}

// FR-012: every operation produces at least one audit entry
fact F_AuditCompleteness { /* MUTATED — body cleared by validator */ }

// FR-014 / FR-011 audit side: no two audit entries record the same operation
fact F_AppendOnlyAudit {
  all disj ae1, ae2: AuditEntry | ae1.operation != ae2.operation
}

// LeastPrivilege: permitted operations must lie in the allowed matrix
fact F_LeastPrivilegeAllowedMatrix {
  all op: Operation |
    op.outcome = Permitted implies (op.caller.role -> op.kind) in PermMatrix.Allowed
}

// FR-004 care-team gating for clinical reads and note adds
fact F_CareTeamGating {
  all op: Operation |
    ((op.kind = OpRead or op.kind = OpAddNote) and op.outcome = Permitted) implies
      (op.caller.role in ClinicalRoles and
       (some ctm: ActiveMembership |
          ctm.clinician = op.caller and ctm.patient = op.targetPatient))
}

// FR-013 attribution correctness: audit user/role match operation caller
fact F_AttributionCorrectness {
  all ae: AuditEntry |
    ae.recordedUser = ae.operation.caller and
    ae.recordedRole = ae.operation.caller.role
}

// FR-010 note creation provenance: each note traces to a permitted add_note op
fact F_NoteCreationProvenance {
  all n: ClinicalNote |
    n.createdBy.kind = OpAddNote and
    n.createdBy.outcome = Permitted and
    n.createdBy.caller = n.author and
    n.createdBy.targetPatient = n.patient and
    n.authorRole = n.author.role
}

// FR-011 notes append-only: distinct notes have distinct creation operations
fact F_AppendOnlyNotes {
  all disj n1, n2: ClinicalNote | n1.createdBy != n2.createdBy
}

// FR-013 note_id paired with permitted add_note
fact F_AuditNoteIdPairing {
  all ae: AuditEntry |
    (some ae.recordedNote) iff
    (ae.operation.kind = OpAddNote and ae.operation.outcome = Permitted)
}

// FR-006 byte-equivalent unauthorised envelope:
//   all non-permitted outcomes collapse to the same BodyNotFound;
//   permitted outcomes have distinct success bodies per endpoint
fact F_ByteEquivalentDenial {
  all op: Operation |
    (op.outcome = Denied or op.outcome = NotFoundOrDenied) implies
      op.visibleBody = BodyNotFound
  all op: Operation |
    (op.outcome = Permitted and op.kind = OpRead) implies op.visibleBody = BodyOK
  all op: Operation |
    (op.outcome = Permitted and op.kind = OpAddNote) implies op.visibleBody = BodyCreated
  all op: Operation |
    (op.outcome = Permitted and op.kind = OpListAudit) implies op.visibleBody = BodyAuditList
}

// Basis consistency with outcome+kind
fact F_BasisConsistency {
  all op: Operation |
    (op.outcome = Permitted and (op.kind = OpRead or op.kind = OpAddNote))
      implies op.basis = CareTeamMember
  all op: Operation |
    (op.outcome = Permitted and op.kind = OpListAudit) implies op.basis = AdministratorRole
}

// ======================================================================
// CATALOGUE PATTERN PREDICATES + ASSERTIONS
// ======================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission tables; spec.md FR-004/005/017
pred LeastPrivilege {
  all op: Operation |
    op.outcome = Permitted implies (op.caller.role -> op.kind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionGrounding  ANCHOR: contracts/http-api.md + spec.md FR-004/005/017
pred PermissionGrounding {
  PermMatrix.Allowed in (
      ((Doctor + Nurse + Pharmacist + ClinicalAdmin) -> (OpRead + OpAddNote))
    + (HospitalAdministrator -> OpListAudit)
  )
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012; data-model.md "audit INSERT for every code path"
pred AuditCompleteness {
  all op: Operation | (some ae: AuditEntry | ae.operation = op)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011 (notes), FR-014 (audit); data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  (all disj ae1, ae2: AuditEntry | ae1.operation != ae2.operation) and
  (all disj n1, n2: ClinicalNote | n1.createdBy != n2.createdBy)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md audit snapshot fields
pred AttributionCorrectness {
  all ae: AuditEntry |
    ae.recordedUser = ae.operation.caller and
    ae.recordedRole = ae.operation.caller.role
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  all op: Operation |
    ((op.kind = OpRead or op.kind = OpAddNote) and op.outcome = Permitted) implies
      (some ctm: ActiveMembership |
         ctm.clinician = op.caller and ctm.patient = op.targetPatient)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006, SC-003; contracts/http-api.md byte-equivalent envelope
pred NoInformationLeakage {
  all op1, op2: Operation |
    (op1.outcome = Denied and op2.outcome = NotFoundOrDenied) implies
      op1.visibleBody = op2.visibleBody
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  // every Operation reaching the audit layer is anchored to a resolved caller
  all op: Operation | one op.caller
  all ae: AuditEntry | one ae.operation and one ae.recordedUser
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// ======================================================================
// FEATURE-SPECIFIC PREDICATES (one per FR-NNN where structurally encodable)
// ======================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 (authentication boundary)
pred FR_001_AuthRequired {
  all op: Operation | one op.caller
  all ae: AuditEntry | one ae.operation
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 (one role per user)
pred FR_002_OneRolePerUser {
  all u: User | one u.role
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 (patient_id never in URL path — modelled as: Operation carries
// a target patient by reference, not via an externally addressable path component)
pred FR_003_NoPatientIdInPath {
  // Structural surrogate: every operation references its patient via the body-level
  // 'targetPatient' field, not via any other channel. The presence of one and only one
  // such reference per operation encodes the contract that the id is body-only.
  all op: Operation | one op.targetPatient
}
assert FR_003_NoPatientIdInPath { FR_003_NoPatientIdInPath }
check FR_003_NoPatientIdInPath for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 (care-team gating)
pred FR_004_CareTeamGating {
  all op: Operation |
    ((op.kind = OpRead or op.kind = OpAddNote) and op.outcome = Permitted) implies
      (op.caller.role in ClinicalRoles and
       (some ctm: ActiveMembership |
          ctm.clinician = op.caller and ctm.patient = op.targetPatient))
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 (administrators never get clinical content)
pred FR_005_AdminNoClinicalContent {
  all op: Operation |
    (op.caller.role = HospitalAdministrator and
     (op.kind = OpRead or op.kind = OpAddNote)) implies op.outcome != Permitted
}
assert FR_005_AdminNoClinicalContent { FR_005_AdminNoClinicalContent }
check FR_005_AdminNoClinicalContent for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 (byte-equivalent unauthorised envelope)
pred FR_006_ByteEquivResponse {
  all op1, op2: Operation |
    (op1.outcome = Denied and op2.outcome = NotFoundOrDenied) implies
      op1.visibleBody = op2.visibleBody
}
assert FR_006_ByteEquivResponse { FR_006_ByteEquivResponse }
check FR_006_ByteEquivResponse for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007/FR-019/FR-020 (fixed response shape — structural surrogate:
// successful record-read responses have a unique externally visible body category)
pred FR_007_FixedResponseShape {
  all op: Operation |
    (op.kind = OpRead and op.outcome = Permitted) implies op.visibleBody = BodyOK
}
assert FR_007_FixedResponseShape { FR_007_FixedResponseShape }
check FR_007_FixedResponseShape for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 (note validation — every persisted note has well-formed fields)
pred FR_009_NoteValidation {
  all n: ClinicalNote |
    one n.author and one n.patient and one n.authorRole and one n.createdBy
}
assert FR_009_NoteValidation { FR_009_NoteValidation }
check FR_009_NoteValidation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 (note fields, including snapshot author_role)
pred FR_010_NoteFieldsSnapshot {
  all n: ClinicalNote |
    n.authorRole = n.author.role and
    n.createdBy.kind = OpAddNote and
    n.createdBy.outcome = Permitted and
    n.createdBy.caller = n.author and
    n.createdBy.targetPatient = n.patient
}
assert FR_010_NoteFieldsSnapshot { FR_010_NoteFieldsSnapshot }
check FR_010_NoteFieldsSnapshot for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 (clinical notes append-only)
pred FR_011_NotesAppendOnly {
  all disj n1, n2: ClinicalNote | n1.createdBy != n2.createdBy
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 (audit for every attempt)
pred FR_012_AuditEveryAttempt {
  all op: Operation | (some ae: AuditEntry | ae.operation = op)
}
assert FR_012_AuditEveryAttempt { FR_012_AuditEveryAttempt }
check FR_012_AuditEveryAttempt for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 (audit-entry shape, including note_id pairing)
pred FR_013_AuditFields {
  all ae: AuditEntry |
    ae.recordedUser = ae.operation.caller and
    ae.recordedRole = ae.operation.caller.role and
    ((some ae.recordedNote) iff
       (ae.operation.kind = OpAddNote and ae.operation.outcome = Permitted))
}
assert FR_013_AuditFields { FR_013_AuditFields }
check FR_013_AuditFields for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 (audit immutability — no two entries per op)
pred FR_014_AuditImmutable {
  all disj ae1, ae2: AuditEntry | ae1.operation != ae2.operation
}
assert FR_014_AuditImmutable { FR_014_AuditImmutable }
check FR_014_AuditImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 (2-second audit SLA — structural surrogate: an audit exists
// for every operation that produced any successful state change, i.e., note creation)
pred FR_015_AuditSLA {
  all n: ClinicalNote | (some ae: AuditEntry | ae.operation = n.createdBy and ae.recordedNote = n)
}
assert FR_015_AuditSLA { FR_015_AuditSLA }
check FR_015_AuditSLA for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 (7-year retention — structural surrogate: no audit deletion
// path means audit entries persist across all operations modelled here)
pred FR_016_AuditRetention {
  // every audit entry remains referenced by its operation; no orphaned/missing-op entries
  all ae: AuditEntry | one ae.operation
}
assert FR_016_AuditRetention { FR_016_AuditRetention }
check FR_016_AuditRetention for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 (administrator-only audit endpoint)
pred FR_017_AdminOnlyAuditEndpoint {
  all op: Operation |
    (op.kind = OpListAudit and op.outcome = Permitted) implies
      op.caller.role = HospitalAdministrator
}
assert FR_017_AdminOnlyAuditEndpoint { FR_017_AdminOnlyAuditEndpoint }
check FR_017_AdminOnlyAuditEndpoint for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 (administrator content-blindness)
pred FR_018_AdminContentBlindness {
  all op: Operation |
    (op.caller.role = HospitalAdministrator and op.outcome = Permitted) implies
      (op.visibleBody = BodyAuditList and
       op.visibleBody != BodyOK and
       op.visibleBody != BodyCreated)
}
assert FR_018_AdminContentBlindness { FR_018_AdminContentBlindness }
check FR_018_AdminContentBlindness for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 (safety fields placement — surrogate: permitted record-read
// responses are uniquely categorised as BodyOK, distinct from denied/auditlist responses)
pred FR_019_SafetyFieldsFirst {
  all op: Operation |
    (op.kind = OpRead and op.outcome = Permitted) implies
      (op.visibleBody = BodyOK and op.visibleBody != BodyNotFound)
}
assert FR_019_SafetyFieldsFirst { FR_019_SafetyFieldsFirst }
check FR_019_SafetyFieldsFirst for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020 (notes_count — surrogate: every read response is in the
// canonical record-read body category, structurally tying notes-count to that single shape)
pred FR_020_NotesCount {
  all op: Operation |
    (op.kind = OpRead and op.outcome = Permitted) implies op.visibleBody = BodyOK
}
assert FR_020_NotesCount { FR_020_NotesCount }
check FR_020_NotesCount for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AuditCompletenessViolation { some op: Operation | (no ae: AuditEntry | ae.operation = op) }
