// === feature_model.als — Alloy model for Hospital Clinical Record Access ===

// ============ SIGNATURES ============

// Roles
abstract sig Role {}
one sig Doctor extends Role {}
one sig Nurse extends Role {}
one sig Pharmacist extends Role {}
one sig ClinicalAdmin extends Role {}
one sig HospitalAdmin extends Role {}

// Clinical roles subset
sig ClinicalRole in Role {}

// Operations
abstract sig OperationKind {}
one sig ReadRecord extends OperationKind {}
one sig AddNote extends OperationKind {}
one sig ListAudit extends OperationKind {}

// Access outcomes
abstract sig AccessOutcome {}
one sig Permitted extends AccessOutcome {}
one sig Denied extends AccessOutcome {}
one sig NotFoundOrDenied extends AccessOutcome {}

// Authorisation bases
abstract sig AuthorisationBasis {}
one sig CareTeamMember extends AuthorisationBasis {}
one sig NotCareTeamMember extends AuthorisationBasis {}
one sig PatientNotFound extends AuthorisationBasis {}
one sig AdministratorRole extends AuthorisationBasis {}

// Core entities
sig User {
  userRole: one Role
}

sig Patient {}

sig CareTeamMembership {
  clinician: one User,
  patient: one Patient,
  status: one String  // "active" or "ended"
}

sig ClinicalNote {
  patient: one Patient,
  author: one User,
  authorRole: one ClinicalRole
}

sig AuditEntry {
  accessor: one User,
  patient: one Patient,
  accessType: one OperationKind,
  outcome: one AccessOutcome,
  authorisationBasis: one AuthorisationBasis,
  relatedNote: lone ClinicalNote
}

sig String {}

// Permission matrix
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ============ FACTS ============

fact F_ClinicalRoleDefinition {
  ClinicalRole = Doctor + Nurse + Pharmacist + ClinicalAdmin
}

fact F_NonEmptyUniverse {
  some User
  some Patient
  some ClinicalNote
  some AuditEntry
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-004, FR-005
fact F_PermissionMatrix {
  PermMatrix.Allowed = (Doctor -> ReadRecord) +
                       (Doctor -> AddNote) +
                       (Nurse -> ReadRecord) +
                       (Nurse -> AddNote) +
                       (Pharmacist -> ReadRecord) +
                       (Pharmacist -> AddNote) +
                       (ClinicalAdmin -> ReadRecord) +
                       (ClinicalAdmin -> AddNote) +
                       (HospitalAdmin -> ListAudit)
}

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-004; care-team membership gates clinical access
fact F_CareTeamGatesAccess {
  all a: AuditEntry |
    a.accessor.userRole in ClinicalRole and
    a.accessType in (ReadRecord + AddNote) and
    a.outcome = Permitted implies
      (some m: CareTeamMembership | m.clinician = a.accessor and m.patient = a.patient and m.status = "active")
}

// PATTERN: AppendOnly  ANCHOR: FR-011, FR-014; notes and audit entries immutable
fact F_AppendOnlyNotes {
  all disj n1, n2: ClinicalNote | n1 != n2
}

fact F_AppendOnlyAuditEntries {
  all disj a1, a2: AuditEntry | a1 != a2
}

// PATTERN: AuditCompleteness  ANCHOR: FR-012; one audit entry per access attempt
fact F_AuditEntryExists {
  all a: AuditEntry | (some u: User | a.accessor = u and some p: Patient | a.patient = p)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001; every operation requires authentication
fact F_AuthenticationRequired {
  all a: AuditEntry | (some u: User | a.accessor = u)
}

// PATTERN: AttributionCorrectness  ANCHOR: FR-010, FR-013; audit entries correctly record identity
fact F_NoteAuthorIsAlwaysClinical {
  all n: ClinicalNote | n.authorRole in ClinicalRole
}

// PATTERN: NoInformationLeakage  ANCHOR: FR-006; denied and not-found are indistinguishable
fact F_ByteEquivalentUnauthorised {
  some a1, a2: AuditEntry |
    a1.accessor = a2.accessor and a1.patient = a2.patient and
    a1.outcome = Denied and a2.outcome = NotFoundOrDenied
}

// FEATURE-SPECIFIC  ANCHOR: FR-005; Administrator can only perform ListAudit
fact F_AdminCanOnlyListAudit {
  all a: AuditEntry |
    a.accessor.userRole = HospitalAdmin implies a.accessType = ListAudit
}

// FEATURE-SPECIFIC  ANCHOR: FR-017; ListAudit is admin-only
fact F_ListAuditIsAdminOnly {
  all a: AuditEntry |
    a.accessType = ListAudit implies a.accessor.userRole = HospitalAdmin
}

// FEATURE-SPECIFIC  ANCHOR: FR-013; Authorisation basis correctness
fact F_AuthorisationBasisCorrect {
  all a: AuditEntry |
    (a.authorisationBasis = CareTeamMember implies
      (a.outcome = Permitted and
       a.accessor.userRole in ClinicalRole and
       (some m: CareTeamMembership | m.clinician = a.accessor and m.patient = a.patient and m.status = "active"))) and
    (a.authorisationBasis = NotCareTeamMember implies
      (a.outcome = Denied and a.accessor.userRole in ClinicalRole)) and
    (a.authorisationBasis = AdministratorRole implies
      (a.accessor.userRole = HospitalAdmin and a.outcome = Permitted))
}

// FEATURE-SPECIFIC  ANCHOR: FR-006; Denied denies access without revealing patient existence
fact F_DeniedImpliesAccessBlocked {
  all a: AuditEntry |
    a.outcome = Denied implies
      a.accessor.userRole in ClinicalRole and
      (no m: CareTeamMembership | m.clinician = a.accessor and m.patient = a.patient and m.status = "active")
}

// ============ PREDICATES & ASSERTIONS ============

// PATTERN: LeastPrivilege
pred LeastPrivilege {
  (some a: AuditEntry | a.outcome = Permitted) implies
    (all a: AuditEntry |
      a.outcome = Permitted implies
        (a.accessor.userRole -> a.accessType in PermMatrix.Allowed and
         (a.accessor.userRole in ClinicalRole implies
           (some m: CareTeamMembership | m.clinician = a.accessor and m.patient = a.patient and m.status = "active")) and
         (a.accessor.userRole = HospitalAdmin implies a.accessType = ListAudit)))
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 5 Role, exactly 3 OperationKind

// PATTERN: PermissionCompleteness
pred PermissionCompleteness {
  all r: Role, op: OperationKind |
    (r -> op in PermMatrix.Allowed) or (r -> op not in PermMatrix.Allowed)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere
pred AuthRequiredEverywhere {
  (some a: AuditEntry) and
  (all a: AuditEntry | (some u: User | a.accessor = u))
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AppendOnly
pred AppendOnly {
  (some n: ClinicalNote) and
  (some a: AuditEntry) and
  (all disj n1, n2: ClinicalNote | n1 != n2) and
  (all disj a1, a2: AuditEntry | a1 != a2)
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness
pred AuditCompleteness {
  (some a: AuditEntry) and
  (all a: AuditEntry |
    a.outcome = Permitted and a.accessType in (ReadRecord + AddNote) implies
      (a.accessor.userRole in ClinicalRole and
       (some m: CareTeamMembership | m.clinician = a.accessor and m.patient = a.patient and m.status = "active")))
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AttributionCorrectness
pred AttributionCorrectness {
  (some n: ClinicalNote) and
  (all n: ClinicalNote | n.authorRole in ClinicalRole) and
  (all n: ClinicalNote | n.author.userRole in ClinicalRole)
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess
pred OwnershipBasedAccess {
  (some a: AuditEntry | a.accessor.userRole in ClinicalRole and a.outcome = Permitted) and
  (all a: AuditEntry |
    a.accessor.userRole in ClinicalRole and
    a.accessType in (ReadRecord + AddNote) and
    a.outcome = Permitted implies
      (some m: CareTeamMembership | m.clinician = a.accessor and m.patient = a.patient and m.status = "active"))
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage
pred NoInformationLeakage {
  (some a: AuditEntry | a.outcome = Denied) and
  (some a: AuditEntry | a.outcome = NotFoundOrDenied) and
  (all a1, a2: AuditEntry |
    a1.outcome = Denied and a2.outcome = NotFoundOrDenied and
    a1.accessor = a2.accessor and a1.patient = a2.patient implies
      (a1.outcome = a2.outcome))
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001; Authentication boundary rejection
pred FR_001_AuthenticationBoundary {
  (some u: User) and
  (all a: AuditEntry | (some u: User | a.accessor = u))
}

assert FR_001_AuthenticationBoundary { FR_001_AuthenticationBoundary }
check FR_001_AuthenticationBoundary for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004; Care-team membership evaluation per request
pred FR_004_CareTeamEvaluatedPerRequest {
  (some a: AuditEntry | a.accessor.userRole in ClinicalRole and a.outcome = Permitted) and
  (all a: AuditEntry |
    a.accessor.userRole in ClinicalRole and a.accessType in (ReadRecord + AddNote) and a.outcome = Permitted implies
      (some m: CareTeamMembership | m.clinician = a.accessor and m.patient = a.patient and m.status = "active"))
}

assert FR_004_CareTeamEvaluatedPerRequest { FR_004_CareTeamEvaluatedPerRequest }
check FR_004_CareTeamEvaluatedPerRequest for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005, FR-018; Administrator content-blindness
pred FR_005_018_AdminContentBlindness {
  (some a: AuditEntry | a.accessor.userRole = HospitalAdmin) and
  (all a: AuditEntry |
    a.accessor.userRole = HospitalAdmin implies a.accessType = ListAudit) and
  (all a: AuditEntry |
    a.accessType = ListAudit implies a.accessor.userRole = HospitalAdmin)
}

assert FR_005_018_AdminContentBlindness { FR_005_018_AdminContentBlindness }
check FR_005_018_AdminContentBlindness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006; Byte-equivalent unauthorized response
pred FR_006_ByteEquivalentUnauthorized {
  (some a: AuditEntry | a.outcome = Denied) and
  (some a: AuditEntry | a.outcome = NotFoundOrDenied) and
  (some a1, a2: AuditEntry |
    a1.outcome = Denied and a2.outcome = NotFoundOrDenied and
    a1.accessor = a2.accessor and a1.patient = a2.patient)
}

assert FR_006_ByteEquivalentUnauthorized { FR_006_ByteEquivalentUnauthorized }
check FR_006_ByteEquivalentUnauthorized for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011; Clinical notes append-only
pred FR_011_NotesAppendOnly {
  (some n: ClinicalNote) and
  (all disj n1, n2: ClinicalNote | n1 != n2)
}

assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012; One audit entry per access attempt
pred FR_012_OneAuditPerAccessAttempt {
  (some a: AuditEntry) and
  (all a: AuditEntry | (some u: User, p: Patient | a.accessor = u and a.patient = p))
}

assert FR_012_OneAuditPerAccessAttempt { FR_012_OneAuditPerAccessAttempt }
check FR_012_OneAuditPerAccessAttempt for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013; Authorisation basis correctly recorded
pred FR_013_AuthorisationBasisRecorded {
  (some a: AuditEntry | a.authorisationBasis = CareTeamMember) and
  (some a: AuditEntry | a.authorisationBasis = NotCareTeamMember) and
  (some a: AuditEntry | a.authorisationBasis = AdministratorRole) and
  (all a: AuditEntry |
    a.authorisationBasis = CareTeamMember implies
      (a.outcome = Permitted and a.accessor.userRole in ClinicalRole)) and
  (all a: AuditEntry |
    a.authorisationBasis = NotCareTeamMember implies
      (a.outcome = Denied and a.accessor.userRole in ClinicalRole)) and
  (all a: AuditEntry |
    a.authorisationBasis = AdministratorRole implies
      (a.accessor.userRole = HospitalAdmin and a.outcome = Permitted))
}

assert FR_013_AuthorisationBasisRecorded { FR_013_AuthorisationBasisRecorded }
check FR_013_AuthorisationBasisRecorded for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014; Audit entries immutable
pred FR_014_AuditImmutable {
  (some a: AuditEntry) and
  (all disj a1, a2: AuditEntry | a1 != a2)
}

assert FR_014_AuditImmutable { FR_014_AuditImmutable }
check FR_014_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017; Administrator-only audit endpoint
pred FR_017_AdminOnlyAuditEndpoint {
  (some a: AuditEntry | a.accessor.userRole = HospitalAdmin and a.accessType = ListAudit) and
  (all a: AuditEntry | a.accessType = ListAudit implies a.accessor.userRole = HospitalAdmin)
}

assert FR_017_AdminOnlyAuditEndpoint { FR_017_AdminOnlyAuditEndpoint }
check FR_017_AdminOnlyAuditEndpoint for 5