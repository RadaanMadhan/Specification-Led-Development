// === feature_model.als — Alloy model for Hospital Clinical Record Access (012-hospital-clinical-records) ===

// ===== ROLE AND OPERATION DEFINITIONS =====
// Five distinct user roles: four clinical + one administrator
abstract sig UserRole {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator extends UserRole {}

// Three endpoint/operation kinds
abstract sig OperationKind {}
one sig ReadRecord, AddNote, ListAudit extends OperationKind {}

// Three possible access outcomes
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// Authorisation basis categories
abstract sig AuthorisationBasis {}
one sig CareTeamMemberBasis, NotCareTeamMemberBasis, PatientNotFoundBasis, AdministratorRoleBasis extends AuthorisationBasis {}

// ===== CORE DATA MODEL ENTITIES =====

sig User {
  userId: one String,
  displayName: one String,
  userRole: one UserRole
}

sig Patient {
  patientId: one String
}

// Care-team membership: clinician linked to patient for active episodes
sig CareTeamMembership {
  clinician: one User,
  patient: one Patient,
  status: one String  // "active" or "ended"
}

// Clinical note: append-only, created by authenticated clinician
sig ClinicalNote {
  noteId: one String,
  patient: one Patient,
  author: one User,
  authorRole: one UserRole,  // Snapshotted at creation
  createdAt: one String,
  noteType: one String,
  body: one String
}

// Audit entry: immutable append-only log of all access attempts
sig AuditEntry {
  auditId: one String,
  user: one User,
  userRole: one UserRole,  // Snapshotted at access time
  patient: one Patient,
  patientId: one String,   // As presented in request
  occurredAt: one String,
  accessType: one OperationKind,
  noteId: lone String,     // Only set for AddNote with Permitted outcome
  outcome: one AccessOutcome,
  authorisationBasis: one AuthorisationBasis
}

// Permission matrix: defines which roles can perform which operations
one sig PermissionMatrix {
  allowed: set UserRole -> OperationKind
}

// ===== NON-EMPTY UNIVERSE CONSTRAINT =====
fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
}

// ===== PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation matrix; spec.md FR-004, FR-005, FR-017

fact F_PermissionMatrixDef {
  // Clinical roles (doctor, nurse, pharmacist, clinical_admin) can read records and add notes
  (Doctor -> ReadRecord) in PermissionMatrix.allowed
  (Doctor -> AddNote) in PermissionMatrix.allowed
  (Nurse -> ReadRecord) in PermissionMatrix.allowed
  (Nurse -> AddNote) in PermissionMatrix.allowed
  (Pharmacist -> ReadRecord) in PermissionMatrix.allowed
  (Pharmacist -> AddNote) in PermissionMatrix.allowed
  (ClinicalAdmin -> ReadRecord) in PermissionMatrix.allowed
  (ClinicalAdmin -> AddNote) in PermissionMatrix.allowed
  
  // Hospital administrator can only list audit logs
  (HospitalAdministrator -> ListAudit) in PermissionMatrix.allowed
  
  // Closed-world assumption: only above permissions are allowed
  PermissionMatrix.allowed = (Doctor -> ReadRecord) +
                             (Doctor -> AddNote) +
                             (Nurse -> ReadRecord) +
                             (Nurse -> AddNote) +
                             (Pharmacist -> ReadRecord) +
                             (Pharmacist -> AddNote) +
                             (ClinicalAdmin -> ReadRecord) +
                             (ClinicalAdmin -> AddNote) +
                             (HospitalAdministrator -> ListAudit)
}

pred LeastPrivilege {
  // Every (role, operation) in the permission matrix matches one of the allowed cells
  all r: UserRole, op: OperationKind |
    (r -> op) in PermissionMatrix.allowed implies (
      (r in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and op in (ReadRecord + AddNote)) or
      (r = HospitalAdministrator and op = ListAudit)
    )
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// ===== PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md CareTeamMembership

fact F_CareTeamGatingRule {
  // For clinical read/add operations: access is permitted iff user is on active care team
  all ae: AuditEntry |
    (ae.accessType = ReadRecord or ae.accessType = AddNote) implies (
      ae.outcome = Permitted iff (
        ae.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
        (some ctm: CareTeamMembership |
          ctm.clinician = ae.user and
          ctm.patient = ae.patient and
          ctm.status = "active")
      )
    )
}

pred CareTeamGating {
  // Verify that permitted clinical accesses correspond to active care-team memberships
  all ae: AuditEntry |
    ae.outcome = Permitted and (ae.accessType = ReadRecord or ae.accessType = AddNote) implies (
      some ctm: CareTeamMembership |
        ctm.clinician = ae.user and ctm.patient = ae.patient and ctm.status = "active"
    )
}

assert CareTeamGating { CareTeamGating }
check CareTeamGating for 5

// ===== FEATURE-SPECIFIC  ANCHOR: FR-005 Administrator content-blindness

fact F_AdministratorRoleRestriction {
  // Hospital administrator can only perform ListAudit operation with Permitted outcome
  all ae: AuditEntry |
    ae.userRole = HospitalAdministrator implies (
      ae.accessType = ListAudit and ae.outcome = Permitted
    )
}

pred AdministratorContentBlindness {
  // No audit entry for an administrator shows ReadRecord or AddNote as Permitted
  all ae: AuditEntry |
    ae.userRole = HospitalAdministrator implies ae.accessType = ListAudit
}

assert AdministratorContentBlindness { AdministratorContentBlindness }
check AdministratorContentBlindness for 5

// ===== PATTERN: AppendOnly  ANCHOR: spec.md FR-011; data-model.md ClinicalNote

pred NotesAppendOnly {
  // Structural: no two notes have the same ID
  all disj n1, n2: ClinicalNote | n1.noteId != n2.noteId
}

assert NotesAppendOnly { NotesAppendOnly }
check NotesAppendOnly for 5

// ===== PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012; data-model.md AuditEntry

fact F_AuditEntryPerNote {
  // Every successful note addition (note creation) produces exactly one matching audit entry
  all n: ClinicalNote |
    (one ae: AuditEntry |
      ae.user = n.author and
      ae.userRole = n.authorRole and
      ae.patient = n.patient and
      ae.accessType = AddNote and
      ae.outcome = Permitted and
      ae.noteId = n.noteId
    )
}

pred AlwaysOnAudit {
  // For each clinical note, there exists a corresponding audit entry with Permitted outcome
  all n: ClinicalNote |
    (some ae: AuditEntry |
      ae.user = n.author and
      ae.accessType = AddNote and
      ae.outcome = Permitted and
      ae.noteId = n.noteId
    )
}

assert AlwaysOnAudit { AlwaysOnAudit }
check AlwaysOnAudit for 5

// ===== PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md AuditEntry

pred AuditAttributionCorrect {
  // Snapshotted user role in audit entry matches the actual user's role
  all ae: AuditEntry | ae.user.userRole = ae.userRole
}

assert AuditAttributionCorrect { AuditAttributionCorrect }
check AuditAttributionCorrect for 5

// ===== PATTERN: AppendOnly (audit)  ANCHOR: spec.md FR-014; data-model.md AuditEntry

pred AuditImmutable {
  // Structural: no two audit entries have the same ID
  all disj ae1, ae2: AuditEntry | ae1.auditId != ae2.auditId
}

assert AuditImmutable { AuditImmutable }
check AuditImmutable for 5

// ===== PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006; contracts/http-api.md byte-equivalent response

pred ByteEquivalentUnauthorised {
  // Denied and NotFoundOrDenied outcomes are distinguishable only by cause, not response
  all ae: AuditEntry |
    (ae.outcome = Denied or ae.outcome = NotFoundOrDenied) implies
      ae.outcome in (Denied + NotFoundOrDenied)
}

assert ByteEquivalentUnauthorised { ByteEquivalentUnauthorised }
check ByteEquivalentUnauthorised for 5

// ===== PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md authentication boundary

pred AuthRequiredEverywhere {
  // Every audit entry is associated with an authenticated user
  all ae: AuditEntry | ae.user in User
  
  // Every clinical note is created by an authenticated user
  all n: ClinicalNote | n.author in User
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// ===== FEATURE-SPECIFIC  ANCHOR: FR-010 Note author must be clinical role

fact F_NoteAuthorMustBeClinical {
  // Clinical notes can only be authored by clinical roles (not administrator)
  all n: ClinicalNote |
    n.authorRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}

pred NoteAuthorClinicalRole {
  all n: ClinicalNote |
    n.authorRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}

assert NoteAuthorClinicalRole { NoteAuthorClinicalRole }
check NoteAuthorClinicalRole for 5

// ===== FEATURE-SPECIFIC  ANCHOR: FR-013 Audit note_id field correctness

fact F_AuditNoteIdPairing {
  // note_id is populated only when access_type = AddNote AND outcome = Permitted
  all ae: AuditEntry |
    (ae.accessType = AddNote and ae.outcome = Permitted) implies ae.noteId != ""
  
  all ae: AuditEntry |
    (ae.accessType != AddNote or ae.outcome != Permitted) implies ae.noteId = ""
}

pred AuditNoteIdCorrect {
  all ae: AuditEntry |
    ae.accessType = AddNote and ae.outcome = Permitted implies ae.noteId != ""
}

assert AuditNoteIdCorrect { AuditNoteIdCorrect }
check AuditNoteIdCorrect for 5

// ===== FEATURE-SPECIFIC  ANCHOR: FR-017 Administrator-only audit listing endpoint

fact F_ListAuditAdminOnly {
  // Only HospitalAdministrator role can perform ListAudit with Permitted outcome
  all ae: AuditEntry |
    (ae.accessType = ListAudit and ae.outcome = Permitted) implies
      ae.userRole = HospitalAdministrator
}

pred AdministratorOnlyListAudit {
  all ae: AuditEntry |
    ae.accessType = ListAudit implies ae.userRole = HospitalAdministrator
}

assert AdministratorOnlyListAudit { AdministratorOnlyListAudit }
check AdministratorOnlyListAudit for 5

// ===== FEATURE-SPECIFIC  ANCHOR: FR-004, FR-013 Authorisation basis correctness

fact F_AuthorisationBasisRule {
  // For successful clinical operations, basis must indicate how access was granted
  all ae: AuditEntry |
    (ae.accessType = ReadRecord or ae.accessType = AddNote) and ae.outcome = Permitted implies
      ae.authorisationBasis = CareTeamMemberBasis
  
  // For administrator audit listing, basis must be administrator role
  all ae: AuditEntry |
    ae.accessType = ListAudit and ae.outcome = Permitted implies
      ae.authorisationBasis = AdministratorRoleBasis
}

pred AuthorisationBasisCorrect {
  all ae: AuditEntry |
    (ae.outcome = Permitted) implies (
      ((ae.accessType = ReadRecord or ae.accessType = AddNote) and
       ae.authorisationBasis = CareTeamMemberBasis) or
      (ae.accessType = ListAudit and ae.authorisationBasis = AdministratorRoleBasis)
    )
}

assert AuthorisationBasisCorrect { AuthorisationBasisCorrect }
check AuthorisationBasisCorrect for 5

// ===== FEATURE-SPECIFIC  ANCHOR: FR-009 Note body must be non-empty

pred NoteBodyNonEmpty {
  all n: ClinicalNote | n.body != ""
}

assert NoteBodyNonEmpty { NoteBodyNonEmpty }
check NoteBodyNonEmpty for 5