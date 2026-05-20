// === feature_model.als — Alloy model for Clinician Access to Patient Medical Records (v1) ===

// Roles in the system
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends Role {}

// Access outcomes
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// Authorisation basis (why access was granted or denied)
abstract sig AuthorisationBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthorisationBasis {}

// Membership status
abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

// Domain entities
sig User {
    role: one Role
}

sig Patient {}

sig CareTeamMembership {
    clinician: one User,
    patient: one Patient,
    status: one MembershipStatus
}

// An access attempt by a user to a patient's record
sig AccessAttempt {
    actor: one User,
    target_patient: one Patient,
    outcome: one AccessOutcome
}

// Immutable audit entry — one per access attempt
sig AuditEntry {
    access_attempt: one AccessAttempt,
    recorded_actor: one User,
    recorded_actor_role: one Role,
    recorded_patient: one Patient,
    outcome: one AccessOutcome,
    authorisation_basis: one AuthorisationBasis
}

// Permission matrix: which roles can perform which operations
abstract sig OperationKind {}
one sig LookupPatientRecord, SearchAuditLog extends OperationKind {}

one sig PermissionMatrix {
    allowed: set Role -> OperationKind
}

// Non-empty universe — required for meaningful assertions
fact F_NonEmptyUniverse {
    some User
    some Patient
    some CareTeamMembership
    some AccessAttempt
    some AuditEntry
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-006, FR-011
pred LeastPrivilege {
    // Clinical roles (doctor, nurse, pharmacist, clinical_admin) can lookup patient records
    Doctor -> LookupPatientRecord in PermissionMatrix.allowed
    Nurse -> LookupPatientRecord in PermissionMatrix.allowed
    Pharmacist -> LookupPatientRecord in PermissionMatrix.allowed
    ClinicalAdmin -> LookupPatientRecord in PermissionMatrix.allowed
    
    // AuditOfficer cannot lookup patient records
    no (AuditOfficer -> LookupPatientRecord) & PermissionMatrix.allowed
    
    // Only AuditOfficer can search the audit log
    AuditOfficer -> SearchAuditLog in PermissionMatrix.allowed
    no (Doctor -> SearchAuditLog) & PermissionMatrix.allowed
    no (Nurse -> SearchAuditLog) & PermissionMatrix.allowed
    no (Pharmacist -> SearchAuditLog) & PermissionMatrix.allowed
    no (ClinicalAdmin -> SearchAuditLog) & PermissionMatrix.allowed
    
    // Closed-world: these are the ONLY allowed permissions
    PermissionMatrix.allowed =
        (Doctor -> LookupPatientRecord) +
        (Nurse -> LookupPatientRecord) +
        (Pharmacist -> LookupPatientRecord) +
        (ClinicalAdmin -> LookupPatientRecord) +
        (AuditOfficer -> SearchAuditLog)
}

assert LeastPrivilege {
    LeastPrivilege
}

check LeastPrivilege for 8 but exactly 5 Role, exactly 2 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, FR-002; contracts/http-api.md authentication section
pred AuthRequiredEverywhere {
    // Every access attempt is made by an authenticated user
    all attempt: AccessAttempt |
        attempt.actor in User
}

assert AuthRequiredEverywhere {
    AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, FR-009; data-model.md audit_entries
pred AuditCompleteness {
    // Every access attempt has exactly one audit entry
    all attempt: AccessAttempt |
        (one audit: AuditEntry | audit.access_attempt = attempt) and
        attempt in AuditEntry.access_attempt
}

assert AuditCompleteness {
    AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, FR-012; contracts/http-api.md no UPDATE/DELETE
pred AppendOnly {
    // All audit entries are distinct; no mutation or deletion
    all disj a1, a2: AuditEntry |
        a1 != a2
}

assert AppendOnly {
    AppendOnly
}

check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009 snapshot semantics
pred AttributionCorrectness {
    // Audit entry's recorded actor and role match the access attempt's actor and role
    all audit: AuditEntry |
        audit.recorded_actor = audit.access_attempt.actor and
        audit.recorded_actor_role = audit.access_attempt.actor.role and
        audit.recorded_patient = audit.access_attempt.target_patient
}

assert AttributionCorrectness {
    AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007; contracts/http-api.md byte-equivalent response
pred NoInformationLeakage {
    // Denied (no care-team membership) and NotFoundOrDenied (patient doesn't exist)
    // are externally indistinguishable; both produce the same response
    all audit: AuditEntry |
        (audit.outcome = Denied or audit.outcome = NotFoundOrDenied) implies
            (audit.outcome in (Denied + NotFoundOrDenied))
}

assert NoInformationLeakage {
    NoInformationLeakage
}

check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-001 authentication required
pred FR_001_AuthenticationRequired {
    all attempt: AccessAttempt |
        attempt.actor in User
}

assert FR_001_AuthenticationRequired {
    FR_001_AuthenticationRequired
}

check FR_001_AuthenticationRequired for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-002 clinician identity resolution
pred FR_002_ClinicianIdentityResolution {
    all user: User |
        user.role in Role
}

assert FR_002_ClinicianIdentityResolution {
    FR_002_ClinicianIdentityResolution
}

check FR_002_ClinicianIdentityResolution for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-005 read-only access
pred FR_005_ReadOnlyAccess {
    // Only read operations are allowed in v1
    all attempt: AccessAttempt |
        attempt.outcome = Permitted implies
            (attempt.actor.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin))
}

assert FR_005_ReadOnlyAccess {
    FR_005_ReadOnlyAccess
}

check FR_005_ReadOnlyAccess for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-006 care-team membership gating
pred FR_006_CareTeamMembershipGating {
    // Access is permitted iff actor is on active care team with target patient
    all attempt: AccessAttempt |
        (attempt.outcome = Permitted) iff (
            attempt.actor.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
            (one member: CareTeamMembership |
                member.clinician = attempt.actor and
                member.patient = attempt.target_patient and
                member.status = Active
            )
        )
}

assert FR_006_CareTeamMembershipGating {
    FR_006_CareTeamMembershipGating
}

check FR_006_CareTeamMembershipGating for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-007 byte-equivalent denied/not-found responses
pred FR_007_ByteEquivalentDeniedNotFound {
    // Denied and NotFoundOrDenied produce identical responses to caller
    all audit: AuditEntry |
        (audit.outcome = Denied or audit.outcome = NotFoundOrDenied) implies
            (audit.outcome in (Denied + NotFoundOrDenied))
}

assert FR_007_ByteEquivalentDeniedNotFound {
    FR_007_ByteEquivalentDeniedNotFound
}

check FR_007_ByteEquivalentDeniedNotFound for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-008 always-on audit
pred FR_008_AlwaysOnAudit {
    // Every access attempt (permitted, denied, or not-found) generates exactly one audit entry
    all attempt: AccessAttempt |
        (one audit: AuditEntry | audit.access_attempt = attempt)
}

assert FR_008_AlwaysOnAudit {
    FR_008_AlwaysOnAudit
}

check FR_008_AlwaysOnAudit for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-009 audit entry shape and contents
pred FR_009_AuditEntryShape {
    all audit: AuditEntry |
        audit.recorded_actor in User and
        audit.recorded_actor_role in Role and
        audit.recorded_patient in Patient and
        audit.outcome in AccessOutcome and
        audit.authorisation_basis in AuthorisationBasis
}

assert FR_009_AuditEntryShape {
    FR_009_AuditEntryShape
}

check FR_009_AuditEntryShape for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-010 audit immutability
pred FR_010_AuditImmutability {
    // No audit entry is ever updated or deleted; each is static
    all audit: AuditEntry |
        audit in AuditEntry
}

assert FR_010_AuditImmutability {
    FR_010_AuditImmutability
}

check FR_010_AuditImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-011 audit readable by IG only
pred FR_011_AuditReadableByIGOnly {
    // Only AuditOfficer can access the audit log search operation
    AuditOfficer -> SearchAuditLog in PermissionMatrix.allowed and
    no (Doctor -> SearchAuditLog) & PermissionMatrix.allowed and
    no (Nurse -> SearchAuditLog) & PermissionMatrix.allowed and
    no (Pharmacist -> SearchAuditLog) & PermissionMatrix.allowed and
    no (ClinicalAdmin -> SearchAuditLog) & PermissionMatrix.allowed
}

assert FR_011_AuditReadableByIGOnly {
    FR_011_AuditReadableByIGOnly
}

check FR_011_AuditReadableByIGOnly for 5

// Fact: Care-team membership determines access for clinical roles
fact F_CareTeamMembershipGates {
    all attempt: AccessAttempt |
        (attempt.actor.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin)) implies (
            (attempt.outcome = Permitted) iff (
                one member: CareTeamMembership |
                    member.clinician = attempt.actor and
                    member.patient = attempt.target_patient and
                    member.status = Active
            )
        )
}

// Fact: Audit entries match and correspond to access attempts
fact F_AuditEntriesMatchAttempts {
    all attempt: AccessAttempt |
        one audit: AuditEntry |
            audit.access_attempt = attempt and
            audit.recorded_actor = attempt.actor and
            audit.recorded_actor_role = attempt.actor.role and
            audit.recorded_patient = attempt.target_patient and
            audit.outcome = attempt.outcome
}

// Fact: Authorisation basis is consistent with outcome
fact F_AuthorisationBasisConsistency {
    all audit: AuditEntry |
        (audit.outcome = Permitted implies audit.authorisation_basis = CareTeamMember) and
        (audit.outcome = Denied implies audit.authorisation_basis = NotCareTeamMember) and
        (audit.outcome = NotFoundOrDenied implies audit.authorisation_basis = PatientNotFound)
}

// Fact: All outcomes are covered
fact F_AllOutcomesCovered {
    all attempt: AccessAttempt |
        attempt.outcome in (Permitted + Denied + NotFoundOrDenied)
}

// Fact: All membership statuses are used
fact F_MembershipStatusCovered {
    all member: CareTeamMembership |
        member.status in (Active + Ended)
}

// Fact: One role per user
fact F_OneRolePerUser {
    all disj u1, u2: User |
        u1.role != u2.role or u1 = u2
}

// === D3 inject_violation (validator-appended) ===
fact MUTATE_AuthBasisInconsistency { some audit: AuditEntry | audit.outcome = Permitted and audit.authorisation_basis != CareTeamMember }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
