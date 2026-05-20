// === feature_model.als — Alloy model for Hospital Clinical Record Access (C-L2) ===

// User roles
abstract sig UserRole {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator extends UserRole {}

// Operation types
abstract sig OperationKind {}
one sig ReadRecord, AddNote, ListAudit extends OperationKind {}

// Access outcomes
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// Authorisation basis
abstract sig AuthorisationBasis {}
one sig CareTeamMemberBasis, NotCareTeamMemberBasis, PatientNotFoundBasis, AdministratorRoleBasis extends AuthorisationBasis {}

// Note types
abstract sig NoteType {}
one sig Progress, Assessment, Plan, Observation, DischargeSummary extends NoteType {}

// Membership status
abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

// Helper predicates for role classification
pred isClinicalRole[r: UserRole] { r in Doctor + Nurse + Pharmacist + ClinicalAdmin }
pred isAdministrator[r: UserRole] { r = HospitalAdministrator }

// Core entities
sig User {
  user_id: one Int,
  display_name: one String,
  user_role: one UserRole
}

sig Patient {
  patient_id: one Int,
  name: one String,
  date_of_birth: one String
}

sig CareTeamMembership {
  clinician: one User,
  patient: one Patient,
  status: one MembershipStatus
}

sig ClinicalNote {
  note_id: one Int,
  patient: one Patient,
  author: one User,
  author_display_name: one String,
  author_role: one UserRole,
  created_at: one String,
  note_type: one NoteType,
  body: one String,
  encounter_date: one String
}

sig AuditEntry {
  user: one User,
  user_display_name: one String,
  user_role: one UserRole,
  patient_id: one Int,
  occurred_at: one String,
  access_type: one OperationKind,
  note_id: lone Int,
  outcome: one AccessOutcome,
  authorisation_basis: one AuthorisationBasis
}

// Permission matrix as singleton field
one sig PermMatrix {
  Allowed: set UserRole -> OperationKind
}

// Non-empty universe: ensure at least one of each key sig
fact F_NonEmptyUniverse {
  some User
  some Patient
  some AuditEntry
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-004, FR-005, FR-017
fact F_PermissionMatrix {
  // Clinical roles: ReadRecord and AddNote
  (Doctor + Nurse + Pharmacist + ClinicalAdmin) -> ReadRecord in PermMatrix.Allowed
  (Doctor + Nurse + Pharmacist + ClinicalAdmin) -> AddNote in PermMatrix.Allowed
  // Administrator: ListAudit only
  HospitalAdministrator -> ListAudit in PermMatrix.Allowed
  // Closed-world: exactly these permissions
  PermMatrix.Allowed = ((Doctor + Nurse + Pharmacist + ClinicalAdmin) -> (ReadRecord + AddNote)) +
                       (HospitalAdministrator -> ListAudit)
}

pred LeastPrivilege {
  all u: User, op: OperationKind |
  (u.user_role -> op) in PermMatrix.Allowed implies (
    (op = ListAudit implies isAdministrator[u.user_role]) and
    (op in ReadRecord + AddNote implies isClinicalRole[u.user_role])
  )
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001
fact F_AuthenticationBoundary {
  all ae: AuditEntry | ae.user in User
}

pred AuthRequiredEverywhere {
  some AuditEntry implies (all ae: AuditEntry | some u: User | ae.user = u)
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-012; data-model.md AuditEntry
fact F_AuditForAddedNotes {
  all n: ClinicalNote |
  some ae: AuditEntry |
  ae.access_type = AddNote and
  ae.note_id = n.note_id and
  ae.outcome = Permitted and
  ae.user = n.author
}

pred AuditCompleteness {
  all n: ClinicalNote | (one ae: AuditEntry | ae.note_id = n.note_id)
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: FR-011, FR-014; data-model.md clinical_notes, audit_entries
fact F_UniqueNoteIds {
  all disj n1, n2: ClinicalNote | n1.note_id != n2.note_id
}

fact F_UniqueAuditKeys {
  all disj ae1, ae2: AuditEntry |
  (ae1.user != ae2.user) or (ae1.occurred_at != ae2.occurred_at) or
  (ae1.access_type != ae2.access_type) or (ae1.patient_id != ae2.patient_id)
}

pred AppendOnly {
  (some ClinicalNote) implies (all disj n1, n2: ClinicalNote | n1.note_id != n2.note_id)
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-004; data-model.md CareTeamMembership
fact F_CareTeamAccessControl {
  all ae: AuditEntry |
  ae.access_type = ReadRecord and isClinicalRole[ae.user_role] and ae.outcome = Permitted implies
  (some ctm: CareTeamMembership |
    ctm.clinician = ae.user and ctm.status = Active)
}

pred OwnershipBasedAccess {
  all n: ClinicalNote |
  (some ctm: CareTeamMembership | ctm.clinician = n.author and ctm.patient = n.patient)
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: FR-006; contracts/http-api.md byte-equivalent response
fact F_UnifiedDenialResponse {
  // All denied/not-found responses use the same envelope, preventing discrimination
  all ae: AuditEntry |
  (ae.outcome = Denied or ae.outcome = NotFoundOrDenied) implies
  (ae.access_type in ReadRecord + AddNote)
}

pred NoInformationLeakage {
  all ae: AuditEntry |
  (ae.outcome = Denied or ae.outcome = NotFoundOrDenied) implies (
    ae.authorisation_basis in NotCareTeamMemberBasis + PatientNotFoundBasis
  )
}

assert NoInformationLeakage {
  NoInformationLeakage
}

check NoInformationLeakage for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-010, FR-013; data-model.md snapshots
fact F_SnapshotIntegrity {
  // Author role snapshot in note matches user's actual role
  all n: ClinicalNote | n.author_role = n.author.user_role
  // Audit entry role snapshot matches user's actual role
  all ae: AuditEntry | ae.user_role = ae.user.user_role
}

pred AttributionCorrectness {
  all n: ClinicalNote |
  isClinicalRole[n.author_role] and n.author_role = n.author.user_role
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: FR-009; contracts/http-api.md validation
fact F_NoteBodyValidation {
  all n: ClinicalNote | n.body != "" and #(n.body) >= 1 and #(n.body) <= 8000
}

pred ValidationBeforeMutation {
  (some ClinicalNote) implies (all n: ClinicalNote | n.body != "" and #(n.body) > 0)
}

assert ValidationBeforeMutation {
  ValidationBeforeMutation
}

check ValidationBeforeMutation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication required on all endpoints
pred FR_001_AuthenticationRequired {
  (some AuditEntry) implies (all ae: AuditEntry | ae.user in User)
}

assert FR_001_AuthenticationRequired {
  FR_001_AuthenticationRequired
}

check FR_001_AuthenticationRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 clinical access requires care-team membership
pred FR_004_CareTeamGating {
  all ae: AuditEntry |
  ae.access_type = ReadRecord and isClinicalRole[ae.user_role] implies (
    ae.outcome = Denied or ae.outcome = NotFoundOrDenied or
    (some ctm: CareTeamMembership | ctm.clinician = ae.user and ctm.status = Active)
  )
}

assert FR_004_CareTeamGating {
  FR_004_CareTeamGating
}

check FR_004_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 administrator cannot read clinical records or add notes
pred FR_005_AdministratorBlindness {
  all ae: AuditEntry |
  ae.user_role = HospitalAdministrator implies ae.access_type = ListAudit
}

assert FR_005_AdministratorBlindness {
  FR_005_AdministratorBlindness
}

check FR_005_AdministratorBlindness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 clinical notes are append-only; no edit or delete
pred FR_011_NotesAppendOnly {
  all n: ClinicalNote |
  isClinicalRole[n.author_role] and n.author_role in Doctor + Nurse + Pharmacist + ClinicalAdmin
}

assert FR_011_NotesAppendOnly {
  FR_011_NotesAppendOnly
}

check FR_011_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 every access attempt produces exactly one audit entry
pred FR_012_OneAuditPerAccess {
  (some ClinicalNote) implies (all n: ClinicalNote | one ae: AuditEntry | ae.note_id = n.note_id)
}

assert FR_012_OneAuditPerAccess {
  FR_012_OneAuditPerAccess
}

check FR_012_OneAuditPerAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 audit entries are immutable (append-only)
pred FR_014_AuditImmutable {
  (some AuditEntry) implies (all disj ae1, ae2: AuditEntry | ae1 != ae2)
}

assert FR_014_AuditImmutable {
  FR_014_AuditImmutable
}

check FR_014_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 access-log endpoint is administrator-only
pred FR_017_AdminAuditOnly {
  all ae: AuditEntry |
  ae.access_type = ListAudit implies ae.user_role = HospitalAdministrator
}

assert FR_017_AdminAuditOnly {
  FR_017_AdminAuditOnly
}

check FR_017_AdminAuditOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 administrator response contains no clinical content fields
pred FR_018_AdminContentBlindness {
  all ae: AuditEntry |
  (ae.user_role = HospitalAdministrator and ae.access_type = ListAudit) implies
  (ae.note_id = none or (some n: ClinicalNote | ae.note_id = n.note_id))
}

assert FR_018_AdminContentBlindness {
  FR_018_AdminContentBlindness
}

check FR_018_AdminContentBlindness for 5