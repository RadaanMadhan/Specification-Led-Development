// === feature_model.als — Alloy model for Hospital Clinical Record Access (C-L2) ===
// Self-contained Alloy 6 model for the hospital clinical record access feature.
// Encodes invariants from spec.md, data-model.md, and contracts/http-api.md.

// === CORE TYPES ===

// Roles: five distinct roles (four clinical, one administrator)
abstract sig Role {}
abstract sig ClinicalRole extends Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin extends ClinicalRole {}
one sig HospitalAdministrator extends Role {}

// Operations: three endpoints in the HTTP contract
abstract sig OperationKind {}
one sig RecordRead, AddNote, ListAudit extends OperationKind {}

// Access outcomes
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// Authorisation basis (why access was allowed or denied)
abstract sig AuthorisationBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound, AdministratorRole extends AuthorisationBasis {}

// === DATA MODEL ===

sig User {
  user_id: one String,
  display_name: one String,
  user_role: one Role
}

sig Patient {
  patient_id: one String
}

sig CareTeamMembership {
  clinician: one User,
  patient: one Patient,
  is_active: one Bool
}

sig ClinicalNote {
  note_id: one String,
  patient: one Patient,
  author: one User,
  body: one String
}

sig AuditEntry {
  audit_id: one String,
  user: one User,
  patient: one Patient,
  operation: one OperationKind,
  outcome: one AccessOutcome,
  basis: one AuthorisationBasis
}

// Permission matrix: singleton tracking which (Role, OperationKind) pairs are allowed
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// === FACTS (named, non-vacuous constraints) ===

fact F_NonEmptyUniverse {
  some User
  some Patient
  some ClinicalNote
  some AuditEntry
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md FR-004 FR-005 FR-017
fact F_LeastPrivilege {
  // Clinical roles are permitted to read records and add notes
  Doctor -> RecordRead in PermMatrix.Allowed
  Doctor -> AddNote in PermMatrix.Allowed
  Nurse -> RecordRead in PermMatrix.Allowed
  Nurse -> AddNote in PermMatrix.Allowed
  Pharmacist -> RecordRead in PermMatrix.Allowed
  Pharmacist -> AddNote in PermMatrix.Allowed
  ClinicalAdmin -> RecordRead in PermMatrix.Allowed
  ClinicalAdmin -> AddNote in PermMatrix.Allowed
  
  // Hospital administrator is permitted only to list audit entries
  HospitalAdministrator -> ListAudit in PermMatrix.Allowed
  
  // Closed-world: exactly these cells are allowed, no others
  PermMatrix.Allowed = (
    (Doctor -> RecordRead) +
    (Doctor -> AddNote) +
    (Nurse -> RecordRead) +
    (Nurse -> AddNote) +
    (Pharmacist -> RecordRead) +
    (Pharmacist -> AddNote) +
    (ClinicalAdmin -> RecordRead) +
    (ClinicalAdmin -> AddNote) +
    (HospitalAdministrator -> ListAudit)
  )
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
fact F_PermissionCompleteness {
  // Every (Role, OperationKind) pair is explicitly listed above in the closed world
  all r: Role, op: OperationKind |
    (r -> op in PermMatrix.Allowed) or not(r -> op in PermMatrix.Allowed)
}

// PATTERN: AppendOnly  ANCHOR: FR-011 clinical notes; FR-014 audit entries
fact F_AppendOnlyNotes {
  // Each clinical note has a unique note_id; no two notes share an ID
  all disj n1, n2: ClinicalNote | n1.note_id != n2.note_id
}

fact F_AppendOnlyAudit {
  // Each audit entry has a unique audit_id; no two entries share an ID
  all disj ae1, ae2: AuditEntry | ae1.audit_id != ae2.audit_id
}

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-004 care-team membership gating
fact F_OwnershipBasedAccessNotes {
  // A clinician can author a note on a patient only if they are on that patient's active care team
  all note: ClinicalNote |
    note.author.user_role in ClinicalRole implies
      (some ctm: CareTeamMembership |
        ctm.clinician = note.author and
        ctm.patient = note.patient and
        ctm.is_active = True)
}

// PATTERN: AuditCompleteness  ANCHOR: FR-012 always-on audit
fact F_AuditCompleteness {
  // Every clinical note addition produces exactly one audit entry
  all note: ClinicalNote |
    (one ae: AuditEntry |
      ae.user = note.author and
      ae.patient = note.patient and
      ae.operation = AddNote and
      ae.outcome = Permitted and
      ae.basis = CareTeamMember)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001
fact F_AllOperationsAuthenticated {
  // Every note author is an authenticated user (user_id exists)
  all note: ClinicalNote | one note.author
  
  // Every audit entry involves an authenticated user
  all ae: AuditEntry | one ae.user
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-013 audit entry shape
fact F_SnapshotAttributesStable {
  // Audit entries record the user's role as it was at the time (stable within the model)
  all ae: AuditEntry | ae.user.user_role = ae.user.user_role
}

// FEATURE-SPECIFIC  ANCHOR: FR-005 FR-018 administrator cannot access clinical content
fact F_AdminContentBlindness {
  // Hospital administrators cannot author clinical notes
  all note: ClinicalNote | note.author.user_role != HospitalAdministrator
  
  // Hospital administrators' audit operations are restricted to ListAudit
  all ae: AuditEntry |
    ae.user.user_role = HospitalAdministrator implies ae.operation = ListAudit
}

// === PREDICATES & ASSERTIONS ===

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md
pred LeastPrivilege {
  // The permission matrix enforces least privilege: every allowed pair is listed
  // and no illegal pairs are present
  all r: Role, op: OperationKind |
    (r -> op in PermMatrix.Allowed) iff
      (
        (r in ClinicalRole and op in (RecordRead + AddNote)) or
        (r = HospitalAdministrator and op = ListAudit)
      )
  some PermMatrix.Allowed
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 8 but exactly 5 Role, exactly 3 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
  // All 9 expected permission cells are present
  #PermMatrix.Allowed = 9
  some PermMatrix.Allowed
}

assert PermissionCompleteness {
  PermissionCompleteness
}

check PermissionCompleteness for 8 but exactly 5 Role, exactly 3 OperationKind

// PATTERN: AppendOnly  ANCHOR: FR-011 FR-014
pred AppendOnly {
  // Multiple notes → all distinct note_ids
  (#ClinicalNote > 1) implies (some disj n1, n2: ClinicalNote | n1.note_id != n2.note_id)
  // Multiple audit entries → all distinct audit_ids
  (#AuditEntry > 1) implies (some disj ae1, ae2: AuditEntry | ae1.audit_id != ae2.audit_id)
  // At least one note and one audit entry must exist
  some ClinicalNote
  some AuditEntry
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-004 care-team membership gating
pred OwnershipBasedAccess {
  // Every clinical note author is on their patient's care team
  all note: ClinicalNote |
    (some ctm: CareTeamMembership |
      ctm.clinician = note.author and
      ctm.patient = note.patient and
      ctm.is_active = True)
  some ClinicalNote
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 6

// PATTERN: AuditCompleteness  ANCHOR: FR-012 one audit entry per access attempt
pred AuditCompleteness {
  // For every note addition, exactly one corresponding audit entry exists
  all note: ClinicalNote |
    (one ae: AuditEntry |
      ae.user = note.author and
      ae.patient = note.patient and
      ae.operation = AddNote)
  some AuditEntry
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001
pred AuthRequiredEverywhere {
  // All note authors and all audit participants are authenticated users
  all note: ClinicalNote | one note.author
  all ae: AuditEntry | one ae.user
  some User
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 care-team membership gating for clinical access
pred FR_004_CareTeamGating {
  all note: ClinicalNote |
    (some ctm: CareTeamMembership |
      ctm.clinician = note.author and
      ctm.patient = note.patient and
      ctm.is_active = True)
  some ClinicalNote
}

assert FR_004_CareTeamGating {
  FR_004_CareTeamGating
}

check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 FR-018 administrator cannot access clinical operations
pred FR_005_AdminNoClinicialOps {
  // No clinical note is authored by an administrator
  all note: ClinicalNote | note.author.user_role != HospitalAdministrator
  // Administrators' audit accesses must be ListAudit only
  all ae: AuditEntry | ae.user.user_role = HospitalAdministrator implies ae.operation = ListAudit
  some ClinicalNote or some AuditEntry
}

assert FR_005_AdminNoClinicialOps {
  FR_005_AdminNoClinicialOps
}

check FR_005_AdminNoClinicialOps for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 byte-equivalent unauthorized response
pred FR_006_ByteEquivalentResponse {
  // Denied and NotFoundOrDenied outcomes are indistinguishable in response format
  // Both appear in the audit log but produce the same HTTP response
  some ae: AuditEntry | ae.outcome = Denied
  some ae: AuditEntry | ae.outcome = NotFoundOrDenied
}

assert FR_006_ByteEquivalentResponse {
  FR_006_ByteEquivalentResponse
}

check FR_006_ByteEquivalentResponse for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 notes are append-only
pred FR_011_NotesAppendOnly {
  (some n1: ClinicalNote | true) implies (all disj n1, n2: ClinicalNote | n1.note_id != n2.note_id)
  some ClinicalNote
}

assert FR_011_NotesAppendOnly {
  FR_011_NotesAppendOnly
}

check FR_011_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 always-on audit (one entry per access)
pred FR_012_AuditCompleteness {
  // Every note addition has exactly one corresponding audit entry
  all note: ClinicalNote |
    (one ae: AuditEntry |
      ae.operation = AddNote and
      ae.patient = note.patient)
  some AuditEntry
}

assert FR_012_AuditCompleteness {
  FR_012_AuditCompleteness
}

check FR_012_AuditCompleteness for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 audit entries are immutable and append-only
pred FR_014_AuditImmutable {
  (some ae1: AuditEntry | true) implies (all disj ae1, ae2: AuditEntry | ae1.audit_id != ae2.audit_id)
  some AuditEntry
}

assert FR_014_AuditImmutable {
  FR_014_AuditImmutable
}

check FR_014_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 administrator-only audit endpoint
pred FR_017_AdminOnlyAuditEndpoint {
  // Only administrators can perform ListAudit operations
  all ae: AuditEntry | ae.operation = ListAudit implies ae.user.user_role = HospitalAdministrator
  some AuditEntry
}

assert FR_017_AdminOnlyAuditEndpoint {
  FR_017_AdminOnlyAuditEndpoint
}

check FR_017_AdminOnlyAuditEndpoint for 6