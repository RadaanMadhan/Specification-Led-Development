// === Hospital Clinical Record Access Feature Model ===
// Feature ID: C-L2
// Spec: Hospital Clinical Record Access (012-hospital-clinical-records)

// ============ TYPE ENUMERATIONS ============

abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

abstract sig NoteType {}
one sig Progress, Assessment, Plan, Observation, DischargeSummary extends NoteType {}

abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

abstract sig AuthorisationBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound, AdminRole extends AuthorisationBasis {}

// ============ ROLES ============
// Five roles total: four clinical + one administrative

abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin extends Role {}
one sig HospitalAdministrator extends Role {}

// ============ OPERATION KINDS ============
// Three operations: read, add_note, list_audit

abstract sig OperationKind {}
one sig RecordRead, AddNote, ListAudit extends OperationKind {}

// ============ MAIN ENTITIES ============

sig User {
  role: one Role
}

sig Patient {
  patient_id: one String
}

sig CareTeamMembership {
  clinician: one User,
  patient: one Patient,
  status: one MembershipStatus
}

sig ClinicalNote {
  note_id: one String,
  patient: one Patient,
  author: one User,
  author_role: one Role
}

sig AuditEntry {
  audit_id: one String,
  user: one User,
  user_role: one Role,
  patient: one Patient,
  access_type: one OperationKind,
  note_id: lone String,
  outcome: one AccessOutcome,
  authorisation_basis: one AuthorisationBasis
}

// ============ PERMISSION MATRIX ============

one sig PermissionMatrix {
  allowed: set Role -> OperationKind
}

// ============ FACTS ============

fact F_NonEmptyUniverse {
  some User
  some Patient
  some AuditEntry
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004, FR-005, FR-017
fact F_PermissionMatrix {
  // Clinical roles (doctor, nurse, pharmacist, clinical_admin) can do RecordRead and AddNote
  Doctor -> RecordRead in PermissionMatrix.allowed
  Doctor -> AddNote in PermissionMatrix.allowed
  Nurse -> RecordRead in PermissionMatrix.allowed
  Nurse -> AddNote in PermissionMatrix.allowed
  Pharmacist -> RecordRead in PermissionMatrix.allowed
  Pharmacist -> AddNote in PermissionMatrix.allowed
  ClinicalAdmin -> RecordRead in PermissionMatrix.allowed
  ClinicalAdmin -> AddNote in PermissionMatrix.allowed
  
  // HospitalAdministrator can only do ListAudit
  HospitalAdministrator -> ListAudit in PermissionMatrix.allowed
  
  // Closed-world assumption
  PermissionMatrix.allowed = 
    ((Doctor + Nurse + Pharmacist + ClinicalAdmin) -> (RecordRead + AddNote)) +
    (HospitalAdministrator -> ListAudit)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md authentication
fact F_AuthRequired {
  // Every audit entry is created by an authenticated user
  all ae: AuditEntry | ae.user in User
}

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-004, FR-005, FR-017
fact F_LeastPrivilege {
  // Every audit entry records an operation the user's role is allowed to perform,
  // or the operation was denied
  all ae: AuditEntry |
    (ae.user.role -> ae.access_type) in PermissionMatrix.allowed or
    (ae.outcome in (Denied + NotFoundOrDenied))
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-004
fact F_CareTeamGating {
  // For clinical operations that succeeded, user must be active care-team member
  all ae: AuditEntry |
    let clinicalOps = RecordRead + AddNote |
    let clinicalRoles = Doctor + Nurse + Pharmacist + ClinicalAdmin |
    (ae.user.role in clinicalRoles and ae.access_type in clinicalOps and ae.outcome = Permitted) implies
      (some ctm: CareTeamMembership |
        ctm.clinician = ae.user and ctm.patient = ae.patient and ctm.status = Active)
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-005
fact F_AdminCannotAccessClinical {
  // HospitalAdministrator can only perform ListAudit operations
  all ae: AuditEntry |
    (ae.user.role = HospitalAdministrator) implies ae.access_type = ListAudit
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011; data-model.md no UPDATE/DELETE on clinical_notes
fact F_NotesAppendOnly {
  // Note IDs are unique and immutable
  all disj n1, n2: ClinicalNote | n1.note_id != n2.note_id
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-014, FR-016; data-model.md no UPDATE/DELETE on audit_entries
fact F_AuditAppendOnly {
  // Audit entry IDs are unique and immutable
  all disj ae1, ae2: AuditEntry | ae1.audit_id != ae2.audit_id
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012, SC-001, SC-002; data-model.md UNIQUE constraint
fact F_AuditCompletenessForNotes {
  // Every successfully-added clinical note has a corresponding audit entry
  all n: ClinicalNote |
    (some ae: AuditEntry |
      ae.access_type = AddNote and
      ae.outcome = Permitted and
      ae.note_id = n.note_id and
      ae.user = n.author and
      ae.patient = n.patient)
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-013; data-model.md AuditEntry CHECK constraint on note_id
fact F_AuditNoteIdConsistency {
  // note_id is populated only when access_type = add_note AND outcome = permitted
  all ae: AuditEntry |
    ((ae.note_id != none) implies
      (ae.access_type = AddNote and ae.outcome = Permitted)) and
    ((ae.access_type = AddNote and ae.outcome = Permitted) implies
      (ae.note_id != none)) and
    ((ae.access_type = AddNote and ae.outcome != Permitted) implies
      (ae.note_id = none)) and
    ((ae.access_type != AddNote) implies
      (ae.note_id = none))
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md user_role snapshot
fact F_AuditUserRoleSnapshot {
  // Audit entry's user_role snapshot matches the user's actual role
  all ae: AuditEntry | ae.user_role = ae.user.role
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-010; data-model.md author_role snapshot
fact F_NoteAuthorRoleSnapshot {
  // Clinical note's author_role snapshot matches the author's actual role
  all n: ClinicalNote | n.author_role = n.author.role
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-011; data-model.md CHECK(author_role IN ('doctor','nurse',...))
fact F_NoteAuthorMustBeClinical {
  // Only clinical roles can author notes; HospitalAdministrator cannot
  all n: ClinicalNote |
    n.author_role in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006; contracts/http-api.md byte-equivalent 404
fact F_NoInformationLeakageOnDenial {
  // When a clinical-role user is denied access, the authorisation_basis must
  // be NotCareTeamMember (not revealing whether patient exists)
  all ae: AuditEntry |
    let clinicalOps = RecordRead + AddNote |
    let clinicalRoles = Doctor + Nurse + Pharmacist + ClinicalAdmin |
    (ae.user.role in clinicalRoles and ae.access_type in clinicalOps and ae.outcome = Denied) implies
      ae.authorisation_basis = NotCareTeamMember
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-017; contracts/http-api.md POST /audit/search
fact F_ListAuditOnlyByAdmin {
  // Only HospitalAdministrator can list audit entries
  all ae: AuditEntry |
    (ae.access_type = ListAudit) implies (ae.user.role = HospitalAdministrator)
}

// ============ PREDICATES & ASSERTIONS ============

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004, FR-005, FR-017
pred LeastPrivilege {
  (some ae: AuditEntry) and
  (all ae: AuditEntry |
    let clinicalRoles = Doctor + Nurse + Pharmacist + ClinicalAdmin |
    let clinicalOps = RecordRead + AddNote |
    (ae.user.role in clinicalRoles implies ae.access_type in clinicalOps) and
    (ae.user.role = HospitalAdministrator implies ae.access_type = ListAudit))
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md authentication
pred AuthRequiredEverywhere {
  all ae: AuditEntry | ae.user in User
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-004
pred CareTeamGatingForClinicals {
  (some ae: AuditEntry | ae.outcome = Permitted) implies
  (all ae: AuditEntry |
    let clinicalOps = RecordRead + AddNote |
    let clinicalRoles = Doctor + Nurse + Pharmacist + ClinicalAdmin |
    (ae.user.role in clinicalRoles and ae.access_type in clinicalOps and ae.outcome = Permitted) implies
      (some ctm: CareTeamMembership |
        ctm.clinician = ae.user and ctm.patient = ae.patient and ctm.status = Active))
}

assert CareTeamGatingForClinicals { CareTeamGatingForClinicals }
check CareTeamGatingForClinicals for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-005
pred AdminCannotAccessClinical {
  all ae: AuditEntry |
    (ae.user.role = HospitalAdministrator) implies ae.access_type = ListAudit
}

assert AdminCannotAccessClinical { AdminCannotAccessClinical }
check AdminCannotAccessClinical for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011; data-model.md no UPDATE/DELETE on clinical_notes
pred NotesAppendOnly {
  (some n: ClinicalNote) implies
  (all disj n1, n2: ClinicalNote | n1.note_id != n2.note_id)
}

assert NotesAppendOnly { NotesAppendOnly }
check NotesAppendOnly for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-014, FR-016; data-model.md no UPDATE/DELETE on audit_entries
pred AuditAppendOnly {
  (some ae: AuditEntry) implies
  (all disj ae1, ae2: AuditEntry | ae1.audit_id != ae2.audit_id)
}

assert AuditAppendOnly { AuditAppendOnly }
check AuditAppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012, SC-001, SC-002
pred AuditCompletenessForNotes {
  all n: ClinicalNote |
    (some ae: AuditEntry |
      ae.access_type = AddNote and
      ae.outcome = Permitted and
      ae.note_id = n.note_id and
      ae.user = n.author and
      ae.patient = n.patient)
}

assert AuditCompletenessForNotes { AuditCompletenessForNotes }
check AuditCompletenessForNotes for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-013; data-model.md AuditEntry CHECK constraint
pred AuditNoteIdOnlyForAddNotePermitted {
  all ae: AuditEntry |
    ((ae.note_id != none) implies
      (ae.access_type = AddNote and ae.outcome = Permitted)) and
    ((ae.access_type = AddNote and ae.outcome = Permitted) implies
      (ae.note_id != none)) and
    ((ae.access_type = AddNote and ae.outcome != Permitted) implies
      (ae.note_id = none)) and
    ((ae.access_type != AddNote) implies
      (ae.note_id = none))
}

assert AuditNoteIdOnlyForAddNotePermitted { AuditNoteIdOnlyForAddNotePermitted }
check AuditNoteIdOnlyForAddNotePermitted for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md user_role snapshot
pred AuditUserRoleSnapshot {
  all ae: AuditEntry | ae.user_role = ae.user.role
}

assert AuditUserRoleSnapshot { AuditUserRoleSnapshot }
check AuditUserRoleSnapshot for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-010; data-model.md author_role snapshot
pred NoteAuthorRoleSnapshot {
  all n: ClinicalNote | n.author_role = n.author.role
}

assert NoteAuthorRoleSnapshot { NoteAuthorRoleSnapshot }
check NoteAuthorRoleSnapshot for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-011; data-model.md CHECK(author_role IN (...))
pred NoteAuthorsAreClinical {
  all n: ClinicalNote |
    n.author_role in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}

assert NoteAuthorsAreClinical { NoteAuthorsAreClinical }
check NoteAuthorsAreClinical for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006; contracts/http-api.md byte-equivalent 404
pred NoInformationLeakageOnDenial {
  all ae: AuditEntry |
    let clinicalOps = RecordRead + AddNote |
    let clinicalRoles = Doctor + Nurse + Pharmacist + ClinicalAdmin |
    (ae.user.role in clinicalRoles and ae.access_type in clinicalOps and ae.outcome = Denied) implies
      ae.authorisation_basis = NotCareTeamMember
}

assert NoInformationLeakageOnDenial { NoInformationLeakageOnDenial }
check NoInformationLeakageOnDenial for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-017; contracts/http-api.md POST /audit/search
pred ListAuditOnlyByAdmin {
  all ae: AuditEntry |
    (ae.access_type = ListAudit) implies (ae.user.role = HospitalAdministrator)
}

assert ListAuditOnlyByAdmin { ListAuditOnlyByAdmin }
check ListAuditOnlyByAdmin for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-009; contracts/http-api.md note validation
pred ValidNoteTypeOnly {
  all n: ClinicalNote |
    n.note_type in (Progress + Assessment + Plan + Observation + DischargeSummary)
}

assert ValidNoteTypeOnly { ValidNoteTypeOnly }
check ValidNoteTypeOnly for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-012; contracts/http-api.md audit outcomes
pred ValidAuditOutcome {
  all ae: AuditEntry |
    ae.outcome in (Permitted + Denied + NotFoundOrDenied)
}

assert ValidAuditOutcome { ValidAuditOutcome }
check ValidAuditOutcome for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-013; contracts/http-api.md authorisation basis
pred ValidAuthorisationBasis {
  all ae: AuditEntry |
    ae.authorisation_basis in (CareTeamMember + NotCareTeamMember + PatientNotFound + AdminRole)
}

assert ValidAuthorisationBasis { ValidAuthorisationBasis }
check ValidAuthorisationBasis for 5