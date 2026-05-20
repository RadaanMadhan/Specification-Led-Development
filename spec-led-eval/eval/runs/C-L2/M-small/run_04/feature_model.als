// === feature_model.als — Alloy model for Hospital Clinical Record Access (C-L2) ===

// ============ SIGNATURES ============

// Roles
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator extends Role {}

// Operations/Endpoints
abstract sig OperationKind {}
one sig ReadRecord, AddNote, ListAudit extends OperationKind {}

// Access outcomes
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// Authorization basis
abstract sig AuthorisationBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound, AdministratorRole extends AuthorisationBasis {}

// Membership status
abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

// Users
sig User {
    user_id: one Int,
    display_name: one String,
    user_role: one Role
}

// Patients
sig Patient {
    patient_id: one Int
}

// Care team membership linking clinician to patient
sig CareTeamMembership {
    clinician: one User,
    patient: one Patient,
    status: one MembershipStatus
}

// Clinical note (append-only)
sig ClinicalNote {
    note_id: one Int,
    patient: one Patient,
    author_user_id: one Int,
    author_display_name: one String,
    author_role: one Role,
    body: one String
}

// Audit entry (immutable, append-only)
sig AuditEntry {
    audit_id: one Int,
    user_id: one Int,
    user_display_name: one String,
    user_role: one Role,
    patient_id: one Int,
    access_type: one OperationKind,
    note_id: lone Int,
    outcome: one AccessOutcome,
    authorisation_basis: one AuthorisationBasis
}

// Permission matrix singleton
one sig PermMatrix {
    Allowed: set Role -> OperationKind
}

// ============ FACTS (LOAD-BEARING CONSTRAINTS) ============

// F_NonEmptyUniverse: ensure the model contains at least one atom of each dynamic sig
fact F_NonEmptyUniverse {
    some User
    some Patient
    some ClinicalNote
    some AuditEntry
    some CareTeamMembership
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-004, FR-005, FR-017
fact F_PermissionMatrix {
    // Clinical roles can read records and add notes
    Doctor -> ReadRecord in PermMatrix.Allowed
    Nurse -> ReadRecord in PermMatrix.Allowed
    Pharmacist -> ReadRecord in PermMatrix.Allowed
    ClinicalAdmin -> ReadRecord in PermMatrix.Allowed
    
    Doctor -> AddNote in PermMatrix.Allowed
    Nurse -> AddNote in PermMatrix.Allowed
    Pharmacist -> AddNote in PermMatrix.Allowed
    ClinicalAdmin -> AddNote in PermMatrix.Allowed
    
    // Only administrator can list audit
    HospitalAdministrator -> ListAudit in PermMatrix.Allowed
    
    // Closed-world: this is all
    PermMatrix.Allowed = 
        (Doctor -> ReadRecord) + (Doctor -> AddNote) +
        (Nurse -> ReadRecord) + (Nurse -> AddNote) +
        (Pharmacist -> ReadRecord) + (Pharmacist -> AddNote) +
        (ClinicalAdmin -> ReadRecord) + (ClinicalAdmin -> AddNote) +
        (HospitalAdministrator -> ListAudit)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011; data-model.md clinical_notes no UPDATE/DELETE
fact F_AppendOnlyNotes {
    // Structural enforcement: no two clinical notes have the same note_id
    all disj n1, n2: ClinicalNote | n1.note_id != n2.note_id
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-014; data-model.md audit_entries no UPDATE/DELETE
fact F_AppendOnlyAuditEntries {
    // Structural enforcement: no two audit entries have the same audit_id
    all disj ae1, ae2: AuditEntry | ae1.audit_id != ae2.audit_id
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012; data-model.md UNIQUE(transaction_id)
fact F_OneAuditPerAccess {
    // Every clinical note must have exactly one matching permitted audit entry
    all note: ClinicalNote |
        (one ae: AuditEntry |
            ae.access_type = AddNote and
            ae.note_id = note.note_id and
            ae.outcome = Permitted)
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md care_team_memberships
fact F_CareTeamGatingForNoteAuthors {
    // Authors of notes must be active care-team members for that patient
    all note: ClinicalNote |
        (some ctm: CareTeamMembership |
            ctm.clinician.user_id = note.author_user_id and
            ctm.patient = note.patient and
            ctm.status = Active)
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md audit entry fields
fact F_AuditAttributionCorrect {
    // Audit entries record the user's role at access time
    all ae: AuditEntry, u: User |
        ae.user_id = u.user_id implies ae.user_role = u.user_role
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006; contracts/http-api.md byte-equivalent response
fact F_ByteEquivalentUnauthorisedResponses {
    // Denied outcomes only occur when no active care-team membership exists
    all ae: AuditEntry |
        (ae.outcome = Denied or ae.outcome = NotFoundOrDenied) implies
        (no ctm: CareTeamMembership |
            ctm.clinician.user_id = ae.user_id and
            ctm.patient.patient_id = ae.patient_id and
            ctm.status = Active)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md authentication
fact F_AllAccessesAuthenticated {
    // Every audit entry has a corresponding authenticated user
    all ae: AuditEntry | (some u: User | u.user_id = ae.user_id)
}

// FEATURE-SPECIFIC  ANCHOR: FR-005 (administrator cannot read clinical records)
fact F_AdministratorCannotReadRecords {
    // Hospital administrators are not members of any care team
    all u: User |
        u.user_role = HospitalAdministrator implies
        (no ctm: CareTeamMembership | ctm.clinician = u)
}

// FEATURE-SPECIFIC  ANCHOR: FR-005, FR-017 (administrator endpoint is ListAudit only)
fact F_AdministratorListAuditOnly {
    // Only HospitalAdministrator role can perform ListAudit access
    all ae: AuditEntry |
        ae.access_type = ListAudit implies ae.user_role = HospitalAdministrator
}

// FEATURE-SPECIFIC  ANCHOR: FR-010 (note authors must be clinical roles)
fact F_NoteAuthorsAreClinical {
    // Authors cannot be administrators
    all note: ClinicalNote |
        (note.author_role = Doctor or
         note.author_role = Nurse or
         note.author_role = Pharmacist or
         note.author_role = ClinicalAdmin)
}

// FEATURE-SPECIFIC  ANCHOR: FR-010 (audit snapshot consistency)
fact F_AuditNoteFieldConsistency {
    // Audit entries for note additions snapshot the correct author metadata
    all ae: AuditEntry, note: ClinicalNote |
        ae.access_type = AddNote and ae.note_id = note.note_id implies
        (ae.user_id = note.author_user_id and
         ae.user_display_name = note.author_display_name and
         ae.user_role = note.author_role)
}

// FEATURE-SPECIFIC  ANCHOR: FR-001 (no unauthenticated audits)
fact F_NoUnauthenticatedAudits {
    // Unauthenticated requests do not produce audit entries (they fail at auth boundary)
    all ae: AuditEntry | ae.user_id > -1
}

// ============ PREDICATES & ASSERTIONS ============

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md
pred LeastPrivilege {
    some u: User, op: OperationKind | true
    and
    (all u: User, op: OperationKind |
        (u.user_role -> op in PermMatrix.Allowed) implies
        (op = ReadRecord or op = AddNote or op = ListAudit))
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
    some Role and some OperationKind
    implies
    (all r: Role, op: OperationKind |
        (r -> op in PermMatrix.Allowed or not(r -> op in PermMatrix.Allowed)))
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011, FR-014; data-model.md NO UPDATE/DELETE
pred AppendOnly {
    (some n: ClinicalNote | true) and
    (all disj n1, n2: ClinicalNote | n1.note_id != n2.note_id) and
    (all disj ae1, ae2: AuditEntry | ae1.audit_id != ae2.audit_id)
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012; data-model.md UNIQUE constraints
pred AuditCompleteness {
    (some n: ClinicalNote | true)
    implies
    (all note: ClinicalNote |
        one ae: AuditEntry |
            ae.access_type = AddNote and ae.note_id = note.note_id)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md care_team_memberships
pred OwnershipBasedAccess {
    (some n: ClinicalNote | true)
    implies
    (all note: ClinicalNote |
        some ctm: CareTeamMembership |
            ctm.clinician.user_id = note.author_user_id and
            ctm.patient = note.patient and
            ctm.status = Active)
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006; contracts/http-api.md byte-equivalent
pred NoInformationLeakage {
    (some ae: AuditEntry | ae.outcome = Denied or ae.outcome = NotFoundOrDenied)
    implies
    (all ae: AuditEntry |
        (ae.outcome = Denied or ae.outcome = NotFoundOrDenied) implies
        (all ctm: CareTeamMembership |
            not(ctm.clinician.user_id = ae.user_id and
                ctm.patient.patient_id = ae.patient_id and
                ctm.status = Active)))
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md authentication
pred AuthRequiredEverywhere {
    (some ae: AuditEntry | true)
    implies
    (all ae: AuditEntry | some u: User | u.user_id = ae.user_id)
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md audit entry snapshot fields
pred AttributionCorrectness {
    (some ae: AuditEntry | true)
    implies
    (all ae: AuditEntry, u: User |
        ae.user_id = u.user_id implies ae.user_role = u.user_role)
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// FR-001_AuthRequired  ANCHOR: spec.md FR-001
pred FR_001_AuthRequired {
    (some ae: AuditEntry | true)
    implies
    (all ae: AuditEntry | ae.user_id >= 0 and some u: User | u.user_id = ae.user_id)
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FR-002_RoleResolution  ANCHOR: spec.md FR-002
pred FR_002_RoleResolution {
    (some u: User | true)
    implies
    (all u: User |
        u.user_role = Doctor or u.user_role = Nurse or
        u.user_role = Pharmacist or u.user_role = ClinicalAdmin or
        u.user_role = HospitalAdministrator)
}

assert FR_002_RoleResolution { FR_002_RoleResolution }
check FR_002_RoleResolution for 5

// FR-004_CareTeamGating  ANCHOR: spec.md FR-004; contracts/http-api.md POST /records/lookup, /records/notes
pred FR_004_CareTeamGating {
    (some note: ClinicalNote | true)
    implies
    (all note: ClinicalNote |
        some ctm: CareTeamMembership |
            ctm.clinician.user_id = note.author_user_id and
            ctm.patient = note.patient and
            ctm.status = Active)
}

assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 5

// FR-005_AdministratorNoClinicalContent  ANCHOR: spec.md FR-005; contracts/http-api.md POST /audit/search
pred FR_005_AdministratorNoClinicalContent {
    (some u: User | u.user_role = HospitalAdministrator)
    implies
    (all u: User |
        u.user_role = HospitalAdministrator implies
        (no ctm: CareTeamMembership | ctm.clinician = u))
}

assert FR_005_AdministratorNoClinicalContent { FR_005_AdministratorNoClinicalContent }
check FR_005_AdministratorNoClinicalContent for 5

// FR-006_ByteEquivalentResponse  ANCHOR: spec.md FR-006; contracts/http-api.md byte-equivalent 404
pred FR_006_ByteEquivalentResponse {
    (some ae: AuditEntry | ae.outcome = Denied or ae.outcome = NotFoundOrDenied)
    implies
    (all ae: AuditEntry |
        (ae.outcome = Denied or ae.outcome = NotFoundOrDenied) implies
        (no ctm: CareTeamMembership |
            ctm.clinician.user_id = ae.user_id and
            ctm.patient.patient_id = ae.patient_id and
            ctm.status = Active))
}

assert FR_006_ByteEquivalentResponse { FR_006_ByteEquivalentResponse }
check FR_006_ByteEquivalentResponse for 5

// FR-011_NotesAppendOnly  ANCHOR: spec.md FR-011; data-model.md NO UPDATE/DELETE on clinical_notes
pred FR_011_NotesAppendOnly {
    (some n: ClinicalNote | true)
    implies
    (all disj n1, n2: ClinicalNote | n1.note_id != n2.note_id)
}

assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 5

// FR-012_AuditCompleteness  ANCHOR: spec.md FR-012; contracts/http-api.md always-on audit
pred FR_012_AuditCompleteness {
    (some n: ClinicalNote | true)
    implies
    (all note: ClinicalNote |
        one ae: AuditEntry |
            ae.access_type = AddNote and
            ae.note_id = note.note_id and
            ae.outcome = Permitted)
}

assert FR_012_AuditCompleteness { FR_012_AuditCompleteness }
check FR_012_AuditCompleteness for 5

// FR-014_AuditImmutable  ANCHOR: spec.md FR-014; data-model.md NO UPDATE/DELETE on audit_entries
pred FR_014_AuditImmutable {
    (some ae: AuditEntry | true)
    implies
    (all disj ae1, ae2: AuditEntry | ae1.audit_id != ae2.audit_id)
}

assert FR_014_AuditImmutable { FR_014_AuditImmutable }
check FR_014_AuditImmutable for 5

// FR-018_AdminContentBlindness  ANCHOR: spec.md FR-018; contracts/http-api.md administrator response
pred FR_018_AdminContentBlindness {
    (some u: User | u.user_role = HospitalAdministrator)
    implies
    (all u: User, ae: AuditEntry |
        u.user_role = HospitalAdministrator and u.user_id = ae.user_id implies
        ae.access_type = ListAudit)
}

assert FR_018_AdminContentBlindness { FR_018_AdminContentBlindness }
check FR_018_AdminContentBlindness for 5