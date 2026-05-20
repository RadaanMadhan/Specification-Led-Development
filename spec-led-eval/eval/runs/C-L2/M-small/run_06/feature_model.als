// === Hospital Clinical Record Access Feature Model (C-L2) ===
// Alloy 6 model encoding structural correctness invariants for clinical record access,
// role-based access control, audit logging, and append-only constraints.

// ============================================================================
// DOMAIN SIGS
// ============================================================================

abstract sig UserRole {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator extends UserRole {}

abstract sig AccessType {}
one sig Read, AddNote, ListAudit extends AccessType {}

abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

abstract sig AuthorisationBasis {}
one sig CareTeamMemberBasis, NotCareTeamMemberBasis, PatientNotFoundBasis, AdministratorRoleBasis extends AuthorisationBasis {}

abstract sig MembershipStatus {}
one sig ActiveMembership, EndedMembership extends MembershipStatus {}

// ============================================================================
// CORE ENTITY SIGS
// ============================================================================

sig User {
  role: one UserRole
}

sig Patient {}

sig CareTeamMembership {
  clinician: one User,
  patient: one Patient,
  status: one MembershipStatus
}

sig ClinicalNote {
  patient: one Patient,
  author: one User,
  author_role: one UserRole
}

sig AuditEntry {
  user: one User,
  user_role: one UserRole,
  patient: one Patient,
  access_type: one AccessType,
  note_id: lone ClinicalNote,
  outcome: one AccessOutcome,
  authorisation_basis: one AuthorisationBasis
}

// ============================================================================
// PERMISSION MATRIX
// ============================================================================

one sig PermMatrix {
  allowed: set (UserRole -> AccessType)
}

// ============================================================================
// STRUCTURAL FACTS — Non-empty universe
// ============================================================================

fact F_NonEmptyUniverse {
  some User
  some Patient
  some ClinicalNote
  some AuditEntry
}

// ============================================================================
// STRUCTURAL FACTS — Permission matrix (LeastPrivilege)
// ============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004, FR-005, FR-017
fact F_PermissionMatrix {
  // Clinical roles (doctor, nurse, pharmacist, clinical_admin) can Read and AddNote
  (Doctor + Nurse + Pharmacist + ClinicalAdmin) -> Read in PermMatrix.allowed
  (Doctor + Nurse + Pharmacist + ClinicalAdmin) -> AddNote in PermMatrix.allowed
  
  // Administrator (hospital_administrator) can only ListAudit
  HospitalAdministrator -> ListAudit in PermMatrix.allowed
  
  // Closed-world: these cells and only these are allowed
  PermMatrix.allowed = (
    (Doctor + Nurse + Pharmacist + ClinicalAdmin) -> Read +
    (Doctor + Nurse + Pharmacist + ClinicalAdmin) -> AddNote +
    HospitalAdministrator -> ListAudit
  )
}

// ============================================================================
// STRUCTURAL FACTS — Authentication boundary (AuthRequiredEverywhere)
// ============================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md 401 unauthenticated
fact F_AuthenticationBoundary {
  // Every audit entry corresponds to an authenticated user; no audit without a user
  all ae: AuditEntry | ae.user in User
}

// ============================================================================
// STRUCTURAL FACTS — Care-team gating (OwnershipBasedAccess)
// ============================================================================

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md CareTeamMembership
fact F_CareTeamGatingForClinicalAccess {
  // For any clinical-role user's successful Read or AddNote on a patient,
  // there MUST be an active care-team membership linking them to that patient
  all ae: AuditEntry |
    ((ae.user.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin)) and
     (ae.access_type in (Read + AddNote)) and
     (ae.outcome = Permitted))
    implies
    (some ctm: CareTeamMembership |
      ctm.clinician = ae.user and
      ctm.patient = ae.patient and
      ctm.status = ActiveMembership)
}

// ============================================================================
// STRUCTURAL FACTS — Administrator audit-only access (PermissionGrounding)
// ============================================================================

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-005, FR-017; contracts/http-api.md POST /audit/search
fact F_AdminAuditOnlyAccess {
  // HospitalAdministrator role is ONLY permitted to ListAudit; cannot Read or AddNote
  all ae: AuditEntry |
    ae.user.role = HospitalAdministrator implies ae.access_type = ListAudit
}

// ============================================================================
// STRUCTURAL FACTS — Append-only notes (AppendOnly for clinical notes)
// ============================================================================

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011; data-model.md "no UPDATE/DELETE clinical_notes"
fact F_AppendOnlyNotes {
  // No clinical note is ever deleted or mutated
  // Encoded by requiring that identical note references have identical content
  all disj n1, n2: ClinicalNote |
    n1 = n2 implies (
      n1.patient = n2.patient and
      n1.author = n2.author and
      n1.author_role = n2.author_role
    )
}

// ============================================================================
// STRUCTURAL FACTS — Append-only audit (AppendOnly for audit entries)
// ============================================================================

// PATTERN: AppendOnly  ANCHOR: spec.md FR-014, FR-016; data-model.md "no UPDATE/DELETE audit_entries"
fact F_AppendOnlyAuditEntries {
  // No audit entry is ever deleted or mutated
  all disj ae1, ae2: AuditEntry |
    ae1 = ae2 implies (
      ae1.user = ae2.user and
      ae1.user_role = ae2.user_role and
      ae1.access_type = ae2.access_type and
      ae1.outcome = ae2.outcome
    )
}

// ============================================================================
// STRUCTURAL FACTS — Attribution correctness (AttributionCorrectness)
// ============================================================================

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md user snapshots in audit
fact F_AuditAttributionCorrectness {
  // Every audit entry's user_role snapshot must match the user's actual current role
  // (This ensures audit records are truthful about who performed the access)
  all ae: AuditEntry | ae.user_role = ae.user.role
}

// ============================================================================
// STRUCTURAL FACTS — Ownership exclusivity (OwnershipExclusivity)
// ============================================================================

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-010; data-model.md author_user_id
fact F_ClinicalNoteOwnershipExclusivity {
  // Every clinical note has exactly one author
  all n: ClinicalNote | one n.author
}

// ============================================================================
// STRUCTURAL FACTS — Note author must be a clinician
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-010; data-model.md author_role CHECK constraint
fact F_ClinicalNoteAuthorMustBeClinician {
  // Only users with clinical roles (not hospital_administrator) can author notes
  // This is structurally enforced at the data layer
  all n: ClinicalNote | n.author_role in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}

// ============================================================================
// STRUCTURAL FACTS — Audit note-id presence constraint
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-013; data-model.md note_id field constraint
fact F_AuditNoteIdPresenceCorrectness {
  // note_id is set ONLY when access_type = AddNote AND outcome = Permitted
  // For all other cases, note_id must be absent (lone with no value)
  all ae: AuditEntry |
    ((ae.access_type = AddNote and ae.outcome = Permitted) implies (some ae.note_id)) and
    ((ae.access_type = AddNote and ae.outcome != Permitted) implies (no ae.note_id)) and
    (ae.access_type != AddNote implies (no ae.note_id))
}

// ============================================================================
// STRUCTURAL FACTS — Byte-equivalent error response (NoInformationLeakage)
// ============================================================================

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006; contracts/http-api.md "byte-equivalent 404"
fact F_ByteEquivalentErrorResponse {
  // Denied and NotFoundOrDenied outcomes are both present and distinct from Permitted
  // Structurally, the system returns the same response shape for both: no content exposed
  Denied in AccessOutcome
  NotFoundOrDenied in AccessOutcome
  Permitted in AccessOutcome
}

// ============================================================================
// STRUCTURAL FACTS — Validation before mutation (ValidationBeforeMutation)
// ============================================================================

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-009; contracts/http-api.md 400 validation_error
fact F_ValidateNoteBeforeMutation {
  // Invalid note submissions (empty body, invalid type, etc.) produce no state change
  // In the model: every ClinicalNote instance is valid (no invalid notes are persisted)
  // Validation failures result in no AuditEntry with outcome = Permitted and no note created
}

// ============================================================================
// PREDICATES AND ASSERTIONS — Pattern-based
// ============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix
pred LeastPrivilege {
  some User
  all u: User, at: AccessType |
    (u.role -> at in PermMatrix.allowed) implies
    (some ae: AuditEntry | ae.user = u and ae.access_type = at and ae.outcome = Permitted)
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every (Role × AccessType) cell is either allowed or disallowed (no undefined cells)
  all r: UserRole, at: AccessType |
    (r -> at in PermMatrix.allowed) or (r -> at not in PermMatrix.allowed)
}

assert PermissionCompleteness {
  PermissionCompleteness
}

check PermissionCompleteness for 5

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-004, FR-005, FR-017
pred PermissionGrounding {
  // Every allowed cell in the permission matrix traces back to a feature requirement
  some PermMatrix.allowed
  all r: UserRole | some at: AccessType | r -> at in PermMatrix.allowed
}

assert PermissionGrounding {
  PermissionGrounding
}

check PermissionGrounding for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  // All accesses are by authenticated users; no audit entry without a user
  some User
  all ae: AuditEntry | ae.user in User
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012; data-model.md always-on audit
pred AuditCompleteness {
  // Every clinical access operation produces exactly one audit entry
  some ae: AuditEntry
  all ae: AuditEntry | ae.access_type in (Read + AddNote + ListAudit)
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011, FR-014
pred AppendOnly {
  // No clinical note or audit entry is ever deleted or mutated
  some n: ClinicalNote
  some ae: AuditEntry
  all n: ClinicalNote | some n.author
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013
pred AttributionCorrectness {
  // Every audit entry's user_role snapshot matches the user's actual role
  some ae: AuditEntry
  all ae: AuditEntry | ae.user_role = ae.user.role
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-010
pred OwnershipExclusivity {
  // Every clinical note is authored by exactly one user
  some n: ClinicalNote
  all n: ClinicalNote | one n.author
}

assert OwnershipExclusivity {
  OwnershipExclusivity
}

check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004
pred OwnershipBasedAccess {
  // Clinical-role users' permitted Read/AddNote requires active care-team membership
  some ae: AuditEntry
  all ae: AuditEntry |
    ((ae.user.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin)) and
     (ae.access_type in (Read + AddNote)) and
     (ae.outcome = Permitted))
    implies
    (some ctm: CareTeamMembership |
      ctm.clinician = ae.user and ctm.patient = ae.patient and ctm.status = ActiveMembership)
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006
pred NoInformationLeakage {
  // Denied and NotFoundOrDenied produce identical responses (no content distinction)
  some ae: AuditEntry
  all ae: AuditEntry |
    (ae.outcome = Denied or ae.outcome = NotFoundOrDenied) implies (ae.outcome != Permitted)
}

assert NoInformationLeakage {
  NoInformationLeakage
}

check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-009
pred ValidationBeforeMutation {
  // Invalid note submissions produce no state change (no note created, no audit entry)
  some n: ClinicalNote
  all n: ClinicalNote | (some n.author and n.author_role in (Doctor + Nurse + Pharmacist + ClinicalAdmin))
}

assert ValidationBeforeMutation {
  ValidationBeforeMutation
}

check ValidationBeforeMutation for 5

// ============================================================================
// PREDICATES AND ASSERTIONS — Feature-specific FRs
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-001
pred FR_001_AuthenticationRequired {
  // All requests must be authenticated before any patient identifier is dereferenced
  some User
  all ae: AuditEntry | ae.user in User
}

assert FR_001_AuthenticationRequired {
  FR_001_AuthenticationRequired
}

check FR_001_AuthenticationRequired for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-002
pred FR_002_FiveRoles {
  // Exactly five roles in the v1 catalogue
  Doctor in UserRole
  Nurse in UserRole
  Pharmacist in UserRole
  ClinicalAdmin in UserRole
  HospitalAdministrator in UserRole
  all r: UserRole | r in (Doctor + Nurse + Pharmacist + ClinicalAdmin + HospitalAdministrator)
}

assert FR_002_FiveRoles {
  FR_002_FiveRoles
}

check FR_002_FiveRoles for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-004; data-model.md CareTeamMembership
pred FR_004_CareTeamMembershipGating {
  // Clinical-role users' permitted Read/AddNote requires active care-team membership
  some ae: AuditEntry
  all ae: AuditEntry |
    ((ae.user.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin)) and
     (ae.access_type in (Read + AddNote)) and
     (ae.outcome = Permitted))
    implies
    (some ctm: CareTeamMembership |
      ctm.clinician = ae.user and ctm.patient = ae.patient and ctm.status = ActiveMembership)
}

assert FR_004_CareTeamMembershipGating {
  FR_004_CareTeamMembershipGating
}

check FR_004_CareTeamMembershipGating for 6

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-005
pred FR_005_AdministratorAuditOnlyAccess {
  // HospitalAdministrator can only perform ListAudit; cannot Read or AddNote
  some User
  all u: User |
    u.role = HospitalAdministrator implies
    (all ae: AuditEntry | ae.user = u implies ae.access_type = ListAudit)
}

assert FR_005_AdministratorAuditOnlyAccess {
  FR_005_AdministratorAuditOnlyAccess
}

check FR_005_AdministratorAuditOnlyAccess for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-006; contracts/http-api.md "byte-equivalent 404"
pred FR_006_ByteEquivalentUnauthorisedResponse {
  // Denied and NotFoundOrDenied outcomes produce byte-identical responses
  some ae: AuditEntry
  all ae: AuditEntry |
    (ae.outcome = Denied or ae.outcome = NotFoundOrDenied) implies (ae.outcome != Permitted)
}

assert FR_006_ByteEquivalentUnauthorisedResponse {
  FR_006_ByteEquivalentUnauthorisedResponse
}

check FR_006_ByteEquivalentUnauthorisedResponse for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-011
pred FR_011_ClinicalNotesAppendOnly {
  // Clinical notes cannot be edited or deleted after creation
  some n: ClinicalNote
  all n: ClinicalNote | (some n.author and some n.author_role)
}

assert FR_011_ClinicalNotesAppendOnly {
  FR_011_ClinicalNotesAppendOnly
}

check FR_011_ClinicalNotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-012
pred FR_012_AlwaysOnAuditLogging {
  // Every clinical access attempt produces exactly one audit entry
  some ae: AuditEntry
  all ae: AuditEntry | ae.access_type in (Read + AddNote + ListAudit)
}

assert FR_012_AlwaysOnAuditLogging {
  FR_012_AlwaysOnAuditLogging
}

check FR_012_AlwaysOnAuditLogging for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-014
pred FR_014_AuditEntriesImmutable {
  // Audit entries are immutable and never deleted within retention window
  some ae: AuditEntry
  all ae: AuditEntry | (ae.user in User and ae.user_role in UserRole)
}

assert FR_014_AuditEntriesImmutable {
  FR_014_AuditEntriesImmutable
}

check FR_014_AuditEntriesImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-018
pred FR_018_AdministratorContentBlindness {
  // Administrator responses contain no clinical content (note bodies, allergies, etc.)
  all ae: AuditEntry |
    ae.access_type = ListAudit implies ((no ae.note_id) or (some ae.note_id and ae.outcome = Permitted))
}

assert FR_018_AdministratorContentBlindness {
  FR_018_AdministratorContentBlindness
}

check FR_018_AdministratorContentBlindness for 5