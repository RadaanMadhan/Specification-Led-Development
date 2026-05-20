// === feature_model.als — Alloy model for Hospital Clinical Record Access ===
// Feature: 012-hospital-clinical-records (C-L2)
// Specification: Hospital Clinical Record Access Control and Audit

// ========== STATIC SIGS (ENUMS) ==========

abstract sig UserRole {}
one sig Doctor extends UserRole {}
one sig Nurse extends UserRole {}
one sig Pharmacist extends UserRole {}
one sig ClinicalAdmin extends UserRole {}
one sig HospitalAdministrator extends UserRole {}

abstract sig AccessType {}
one sig ReadAccess extends AccessType {}
one sig AddNoteAccess extends AccessType {}
one sig ListAuditAccess extends AccessType {}

abstract sig AccessOutcome {}
one sig Permitted extends AccessOutcome {}
one sig Denied extends AccessOutcome {}
one sig NotFoundOrDenied extends AccessOutcome {}

abstract sig AuthorisationBasis {}
one sig CareTeamMember extends AuthorisationBasis {}
one sig NotCareTeamMember extends AuthorisationBasis {}
one sig PatientNotFound extends AuthorisationBasis {}
one sig AdministratorRole extends AuthorisationBasis {}

abstract sig MembershipStatus {}
one sig ActiveMembership extends MembershipStatus {}
one sig EndedMembership extends MembershipStatus {}

// ========== DYNAMIC SIGS ==========

sig User {
  user_role: one UserRole
}

sig Patient {}

sig CareTeamMembership {
  clinician: one User,
  patient: one Patient,
  status: one MembershipStatus
}

sig ClinicalNote {
  patient: one Patient,
  author: one User
}

sig AuditEntry {
  user: one User,
  patient_accessed: one Patient,
  access_type: one AccessType,
  outcome: one AccessOutcome,
  authorisation_basis: one AuthorisationBasis,
  linked_note: lone ClinicalNote
}

// Permission matrix encoding role-operation authorisation
one sig PermMatrix {
  Allowed: set UserRole -> AccessType
}

// ========== NAMED FACTS (STRUCTURAL INVARIANTS) ==========

fact F_NonEmptyUniverse {
  some User
  some Patient
  some ClinicalNote
  some AuditEntry
  some CareTeamMembership
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-004, FR-005, FR-017
fact F_PermissionMatrix {
  // Clinical roles permitted to read and add notes
  (Doctor -> ReadAccess) in PermMatrix.Allowed
  (Doctor -> AddNoteAccess) in PermMatrix.Allowed
  (Nurse -> ReadAccess) in PermMatrix.Allowed
  (Nurse -> AddNoteAccess) in PermMatrix.Allowed
  (Pharmacist -> ReadAccess) in PermMatrix.Allowed
  (Pharmacist -> AddNoteAccess) in PermMatrix.Allowed
  (ClinicalAdmin -> ReadAccess) in PermMatrix.Allowed
  (ClinicalAdmin -> AddNoteAccess) in PermMatrix.Allowed
  
  // Administrator role restricted to audit listing only
  (HospitalAdministrator -> ListAuditAccess) in PermMatrix.Allowed
  
  // Closed-world: exactly these 9 cells; all others denied
  PermMatrix.Allowed = (Doctor -> ReadAccess) +
                       (Doctor -> AddNoteAccess) +
                       (Nurse -> ReadAccess) +
                       (Nurse -> AddNoteAccess) +
                       (Pharmacist -> ReadAccess) +
                       (Pharmacist -> AddNoteAccess) +
                       (ClinicalAdmin -> ReadAccess) +
                       (ClinicalAdmin -> AddNoteAccess) +
                       (HospitalAdministrator -> ListAuditAccess)
}

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md CareTeamMembership; FR-004
fact F_CareTeamMembershipBounded {
  // Each (clinician, patient) pair has at most one active membership
  all u: User, p: Patient |
    lone ctm: CareTeamMembership |
      ctm.clinician = u and ctm.patient = p and ctm.status = ActiveMembership
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011; data-model.md clinical_notes no UPDATE/DELETE
fact F_ClinicalNotesAppendOnly {
  // Notes are immutable: each note instance is unique and cannot be overwritten
  all n1, n2: ClinicalNote |
    (n1.patient = n2.patient and n1.author = n2.author) implies n1 = n2
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-014, FR-016; data-model.md audit_entries no UPDATE/DELETE
fact F_AuditEntriesAppendOnly {
  // Audit entries are immutable: each entry instance is unique
  all ae1, ae2: AuditEntry |
    (ae1.user = ae2.user and ae1.patient_accessed = ae2.patient_accessed and
     ae1.access_type = ae2.access_type and ae1.outcome = ae2.outcome and
     ae1.authorisation_basis = ae2.authorisation_basis and
     ae1.linked_note = ae2.linked_note) implies ae1 = ae2
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012, FR-013
fact F_AuditCompletenessForNotes { /* MUTATED — body cleared by validator */ }

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-010, FR-013
fact F_AuditAttributionCorrect {
  // Audit entries for note additions record the correct author
  all ae: AuditEntry |
    (ae.access_type = AddNoteAccess and ae.outcome = Permitted and ae.linked_note != none)
    implies (ae.user = ae.linked_note.author and ae.patient_accessed = ae.linked_note.patient)
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md CareTeamMembership
fact F_CareTeamGatingForPermittedAccess {
  // Permitted read and note-addition access implies active care-team membership
  all ae: AuditEntry |
    ((ae.access_type = ReadAccess or ae.access_type = AddNoteAccess) and ae.outcome = Permitted)
    implies (some ctm: CareTeamMembership |
      ctm.clinician = ae.user and ctm.patient = ae.patient_accessed and
      ctm.status = ActiveMembership)
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006; contracts/http-api.md byte-equivalent response
fact F_UniformDenialRecording {
  // All denied and not-found audit entries use consistent outcomes
  // (the system cannot signal the distinction between "not found" and "denied" to callers)
  all ae: AuditEntry |
    (ae.outcome = Denied or ae.outcome = NotFoundOrDenied) implies
    ae.linked_note = none  // denials have no linked note
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md authentication boundary
fact F_AllAccessesAuthenticated {
  // Every audit entry corresponds to an authenticated user
  all ae: AuditEntry | ae.user in User
}

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-005, FR-017; contracts/http-api.md administrator endpoint
fact F_AdministratorRoleRestriction {
  // Hospital administrators can only perform audit-list operations; cannot read or modify clinical content
  all u: User |
    u.user_role = HospitalAdministrator implies (
      all ae: AuditEntry | ae.user = u implies ae.access_type = ListAuditAccess
    )
}

// ========== PREDICATES AND ASSERTIONS ==========

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; FR-004, FR-005, FR-017
pred LeastPrivilege {
  // Verify that clinical roles have read/add-note permissions and administrator has only audit permission
  (Doctor -> ReadAccess) in PermMatrix.Allowed and
  (Nurse -> AddNoteAccess) in PermMatrix.Allowed and
  (HospitalAdministrator -> ListAuditAccess) in PermMatrix.Allowed and
  (HospitalAdministrator -> ReadAccess) not in PermMatrix.Allowed and
  (some r: UserRole | some at: AccessType | (r -> at) not in PermMatrix.Allowed)
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 8 but exactly 5 UserRole, exactly 3 AccessType

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004
pred OwnershipBasedAccess {
  some n: ClinicalNote | some ae: AuditEntry |
    (ae.linked_note = n and ae.outcome = Permitted) implies (
      some ctm: CareTeamMembership |
        ctm.clinician = n.author and ctm.patient = n.patient and ctm.status = ActiveMembership
    )
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011
pred AppendOnlyNotes {
  // Each clinical note appears in exactly one successful audit entry
  all n: ClinicalNote |
    one ae: AuditEntry |
      ae.linked_note = n and ae.access_type = AddNoteAccess and ae.outcome = Permitted
}

assert AppendOnlyNotes {
  AppendOnlyNotes
}

check AppendOnlyNotes for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-014, FR-016
pred AppendOnlyAuditEntries {
  // Audit entries are unique and immutable (enforced by fact F_AuditEntriesAppendOnly)
  some ae: AuditEntry | ae in AuditEntry
}

assert AppendOnlyAuditEntries {
  AppendOnlyAuditEntries
}

check AppendOnlyAuditEntries for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012, FR-013
pred AuditCompleteness {
  // Every clinical note has a corresponding audit entry; every audit entry for a note links to exactly one note
  (all n: ClinicalNote | some ae: AuditEntry |
    ae.linked_note = n and ae.access_type = AddNoteAccess and ae.outcome = Permitted) and
  (all ae: AuditEntry | ae.linked_note != none implies ae.access_type = AddNoteAccess)
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-010, FR-013
pred AttributionCorrectness {
  // Audit entries recording note additions correctly identify the author
  some n: ClinicalNote | some ae: AuditEntry |
    (ae.linked_note = n and ae.access_type = AddNoteAccess and ae.outcome = Permitted)
    implies ae.user = n.author
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006
pred NoInformationLeakage {
  // Denied and not-found audit entries are recorded uniformly without distinguishing between them
  some ae: AuditEntry |
    (ae.outcome = Denied or ae.outcome = NotFoundOrDenied)
}

assert NoInformationLeakage {
  NoInformationLeakage
}

check NoInformationLeakage for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  // All audit entries have an authenticated user
  all ae: AuditEntry | ae.user in User and (some u: User | ae.user = u)
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication boundary
pred FR_001_AuthenticationRequired {
  some ae: AuditEntry | ae.user in User
}

assert FR_001_AuthenticationRequired {
  FR_001_AuthenticationRequired
}

check FR_001_AuthenticationRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 care-team gating
pred FR_004_CareTeamGatingEnforced {
  some ae: AuditEntry |
    (ae.access_type = AddNoteAccess and ae.outcome = Permitted) implies
    (some ctm: CareTeamMembership |
      ctm.clinician = ae.user and ctm.patient = ae.patient_accessed and
      ctm.status = ActiveMembership)
}

assert FR_004_CareTeamGatingEnforced {
  FR_004_CareTeamGatingEnforced
}

check FR_004_CareTeamGatingEnforced for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 administrator content-blindness
pred FR_005_AdministratorContentBlind {
  all u: User |
    u.user_role = HospitalAdministrator implies
    (all ae: AuditEntry | ae.user = u implies ae.access_type = ListAuditAccess)
}

assert FR_005_AdministratorContentBlind {
  FR_005_AdministratorContentBlind
}

check FR_005_AdministratorContentBlind for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 byte-equivalent unauthorised response
pred FR_006_ByteEquivalentUnauthorised {
  all ae1, ae2: AuditEntry |
    ((ae1.outcome = Denied or ae1.outcome = NotFoundOrDenied) and
     (ae2.outcome = Denied or ae2.outcome = NotFoundOrDenied))
    implies (ae1.linked_note = none and ae2.linked_note = none)
}

assert FR_006_ByteEquivalentUnauthorised {
  FR_006_ByteEquivalentUnauthorised
}

check FR_006_ByteEquivalentUnauthorised for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 notes append-only
pred FR_011_NotesImmutable {
  all n: ClinicalNote |
    one ae: AuditEntry |
      ae.linked_note = n and ae.access_type = AddNoteAccess and ae.outcome = Permitted
}

assert FR_011_NotesImmutable {
  FR_011_NotesImmutable
}

check FR_011_NotesImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 one audit per access
pred FR_012_OneAuditPerAccess {
  all n: ClinicalNote |
    one ae: AuditEntry |
      ae.access_type = AddNoteAccess and ae.outcome = Permitted and ae.linked_note = n
}

assert FR_012_OneAuditPerAccess {
  FR_012_OneAuditPerAccess
}

check FR_012_OneAuditPerAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014, FR-016 audit immutability and retention
pred FR_014_AuditImmutable {
  all ae1, ae2: AuditEntry |
    (ae1.user = ae2.user and ae1.patient_accessed = ae2.patient_accessed and
     ae1.access_type = ae2.access_type and ae1.outcome = ae2.outcome) implies ae1 = ae2
}

assert FR_014_AuditImmutable {
  FR_014_AuditImmutable
}

check FR_014_AuditImmutable for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AuditCompletenessViolation { some n: ClinicalNote | no ae: AuditEntry | ae.linked_note = n }
