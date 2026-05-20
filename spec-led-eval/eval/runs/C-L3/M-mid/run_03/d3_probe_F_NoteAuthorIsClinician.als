// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===
// Feature: C-L3  (branch: 013-hipaa-clinical-records)
// Generated from: spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────────────────────────────────
// ENUMERATION SIGS  (one sig — no dynamic atoms, no NonEmptyUniverse entry needed)
// ─────────────────────────────────────────────────────────────────────────────

abstract sig Role {}
one sig RoleClinician, RolePatient, RoleComplianceOfficer extends Role {}

// Four endpoints exposed by the feature (FR-004 to FR-007, contracts/http-api.md)
abstract sig OperationKind {}
one sig GetRecord, PostNote, GetRecordAudit, GetAccessLog extends OperationKind {}

abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

// Relationship classifier mirrors data-model Relationship enum
// (computed by permissions.relationship() on every request)
abstract sig Relationship {}
one sig CareTeamClinician, NonCareTeamClinician,
        PatientOwnRecord, PatientOtherRecord,
        ComplianceOfficerRel extends Relationship {}

// ─────────────────────────────────────────────────────────────────────────────
// DYNAMIC ENTITY SIGS
// ─────────────────────────────────────────────────────────────────────────────

sig User {
    userRole: one Role,
    // lone: patients have exactly one; clinicians/compliance officers have none
    assignedRecord: lone Record
}

sig Record {}

// Models only ACTIVE care-team memberships (the only rows that authorise access)
sig CareTeamMembership {
    ctClinician: one User,
    ctRecord:    one Record
}

// Append-only clinical note (FR-011, FR-012)
sig ClinicalNote {
    noteRecord: one Record,
    noteAuthor: one User
}

// Immutable audit entry (FR-013 to FR-017)
sig AuditEntry {
    aeRecord:       lone Record,    // NULL only for GetAccessLog list events
    aeAccessor:     one  User,
    aeAccessorRole: one  Role,      // snapshotted at access time
    aeOperation:    one  OperationKind,
    aeOutcome:      one  Outcome,
    aeNoteRef:      lone ClinicalNote  // non-null iff append+permitted
}

// An Access represents one resolved, authenticated access attempt.
// Unauthenticated requests never become Access atoms (FR-001).
sig Access {
    accUser:    one  User,
    accRecord:  lone Record,       // None for GetAccessLog
    accRel:     one  Relationship,
    accOpKind:  one  OperationKind,
    accOutcome: one  Outcome,
    accAudit:   lone AuditEntry   // exactly one for every Access (enforced by F_AuditCompleteness)
}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (singleton — canonical closed-world table)
// contracts/http-api.md "Permission matrix" table; FR-004 to FR-007
// ─────────────────────────────────────────────────────────────────────────────

one sig PermMatrix {
    allowed: set Relationship -> OperationKind
}

// ─────────────────────────────────────────────────────────────────────────────
// NON-EMPTY UNIVERSE
// ─────────────────────────────────────────────────────────────────────────────

fact F_NonEmptyUniverse {
    some User
    some Record
    some CareTeamMembership
    some ClinicalNote
    some AuditEntry
    some Access
}

// ─────────────────────────────────────────────────────────────────────────────
// STRUCTURAL FACTS
// ─────────────────────────────────────────────────────────────────────────────

// FR-002 / FR-003 / data-model.md users CHECK
// Patients have exactly one assignedRecord; all other roles have none.
fact F_PatientRecordPairing {
    all u: User |
        u.userRole = RolePatient  implies (one u.assignedRecord)
    all u: User |
        u.userRole != RolePatient implies (no u.assignedRecord)
}

// data-model.md care_team_memberships: clinician_id FK -> users with role=clinician
fact F_CareTeamMemberIsClinician {
    all m: CareTeamMembership | m.ctClinician.userRole = RoleClinician
}

// data-model.md clinical_notes: author_role CHECK = 'clinician'  (FR-012)
// Only clinicians can be note authors — structurally impossible for patient/compliance
fact F_NoteAuthorIsClinician {
    all n: ClinicalNote | n.noteAuthor.userRole = RoleClinician
}

// FR-004 / FR-011: a note can only exist if the author is on the care team for that record
fact F_NoteRequiresCareTeamMembership {
    all n: ClinicalNote |
        some m: CareTeamMembership |
            m.ctClinician = n.noteAuthor and m.ctRecord = n.noteRecord
}

// data-model.md audit_entries CHECK (operation, outcome, note_id)
// note_id set iff operation=append AND outcome=permitted (FR-014)
fact F_AuditNoteRefLinkage {
    all ae: AuditEntry |
        (ae.aeOperation = PostNote and ae.aeOutcome = Permitted) implies (one ae.aeNoteRef)
    all ae: AuditEntry |
        (ae.aeOperation != PostNote or ae.aeOutcome = Denied) implies (no ae.aeNoteRef)
}

// data-model.md audit_entries: record_id NULL only for list (GetAccessLog) events
fact F_AuditRecordPresence {
    all ae: AuditEntry |
        ae.aeOperation in (GetRecord + PostNote + GetRecordAudit) implies (one ae.aeRecord)
    all ae: AuditEntry |
        ae.aeOperation = GetAccessLog implies (no ae.aeRecord)
}

// contracts/http-api.md Permission matrix — closed-world encoding
// Rows: CareTeamClinician, NonCareTeamClinician, PatientOwnRecord,
//       PatientOtherRecord, ComplianceOfficerRel
// Columns: GetRecord, PostNote, GetRecordAudit, GetAccessLog
fact F_PermissionMatrix {
    PermMatrix.allowed =
        (CareTeamClinician    -> GetRecord)     +
        (CareTeamClinician    -> PostNote)      +
        (CareTeamClinician    -> GetRecordAudit) +
        (PatientOwnRecord     -> GetRecord)     +
        (PatientOwnRecord     -> GetRecordAudit) +
        (ComplianceOfficerRel -> GetRecordAudit) +
        (ComplianceOfficerRel -> GetAccessLog)
    // All other (Relationship × OperationKind) pairs are implicitly DENIED.
}

// Relationship must be consistent with the user's role in each Access
fact F_RelationshipConsistency {
    all a: Access |
        a.accRel in (CareTeamClinician + NonCareTeamClinician)
            implies a.accUser.userRole = RoleClinician
    all a: Access |
        a.accRel in (PatientOwnRecord + PatientOtherRecord)
            implies a.accUser.userRole = RolePatient
    all a: Access |
        a.accRel = ComplianceOfficerRel
            implies a.accUser.userRole = RoleComplianceOfficer
    // Inverse direction: each role maps to its relationship range
    all a: Access |
        a.accUser.userRole = RoleClinician
            implies a.accRel in (CareTeamClinician + NonCareTeamClinician)
    all a: Access |
        a.accUser.userRole = RolePatient
            implies a.accRel in (PatientOwnRecord + PatientOtherRecord)
    all a: Access |
        a.accUser.userRole = RoleComplianceOfficer
            implies a.accRel = ComplianceOfficerRel
}

// FR-004: CareTeamClinician iff an active membership exists for (clinician, record)
fact F_CareTeamRelationshipCorrectness {
    all a: Access |
        a.accRel = CareTeamClinician implies
            (some m: CareTeamMembership |
                m.ctClinician = a.accUser and m.ctRecord = a.accRecord)
    all a: Access |
        a.accRel = NonCareTeamClinician implies
            (no m: CareTeamMembership |
                m.ctClinician = a.accUser and m.ctRecord = a.accRecord)
}

// FR-006: PatientOwnRecord iff the record is the patient's assigned record
fact F_PatientOwnRecordCorrectness {
    all a: Access |
        a.accRel = PatientOwnRecord implies
            (a.accUser.assignedRecord = a.accRecord)
    all a: Access |
        a.accRel = PatientOtherRecord implies
            (a.accUser.assignedRecord != a.accRecord)
}

// FR-013: every Access produces exactly one AuditEntry, and each AuditEntry
// belongs to exactly one Access (bijection — no orphan audit entries, no duplicates)
fact F_AuditCompleteness {
    all a: Access | one a.accAudit
    all ae: AuditEntry | one a: Access | a.accAudit = ae
}

// FR-014 / AttributionCorrectness: audit entry accurately records accessor identity
fact F_AttributionCorrectness {
    all a: Access |
        let ae = a.accAudit |
            ae.aeAccessor     = a.accUser     and
            ae.aeAccessorRole = a.accUser.userRole and
            ae.aeOperation    = a.accOpKind   and
            ae.aeOutcome      = a.accOutcome  and
            ae.aeRecord       = a.accRecord
}

// FR-008 / LeastPrivilege: access outcome is fully determined by the permission matrix
fact F_OutcomeDeterminedByMatrix {
    all a: Access |
        (a.accRel -> a.accOpKind) in PermMatrix.allowed
            implies a.accOutcome = Permitted
    all a: Access |
        (a.accRel -> a.accOpKind) not in PermMatrix.allowed
            implies a.accOutcome = Denied
}

// GetAccessLog accesses never carry a record reference (they are system-wide)
fact F_AccessLogHasNoRecord {
    all a: Access | a.accOpKind = GetAccessLog implies no a.accRecord
}

// Record-scoped operations must carry a record reference
fact F_RecordScopedOpsHaveRecord {
    all a: Access |
        a.accOpKind in (GetRecord + PostNote + GetRecordAudit)
            implies one a.accRecord
}

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN PREDICATES + ASSERTIONS
// ─────────────────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md Permission matrix; spec.md FR-004 to FR-007
pred LeastPrivilege {
    some Access
    // No denied cell in the matrix results in a Permitted outcome
    all a: Access |
        (a.accRel -> a.accOpKind) not in PermMatrix.allowed
            implies a.accOutcome = Denied
    // Every permitted access traces to an allowed matrix cell
    all a: Access |
        a.accOutcome = Permitted
            implies (a.accRel -> a.accOpKind) in PermMatrix.allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
    some Access
    // Every Access has a definitive outcome — no undefined cell
    all a: Access | a.accOutcome = Permitted or a.accOutcome = Denied
    // The matrix covers all (Relationship × OperationKind) pairs with a verdict
    all r: Relationship, o: OperationKind |
        (r -> o) in PermMatrix.allowed or (r -> o) not in PermMatrix.allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
    some Access
    // Every Access has an authenticated user with a valid role — no "null" accessor
    all a: Access | a.accUser.userRole in (RoleClinician + RolePatient + RoleComplianceOfficer)
    // Audit entries also always have a valid accessor role (snapshotted from auth context)
    all ae: AuditEntry | ae.aeAccessorRole in (RoleClinician + RolePatient + RoleComplianceOfficer)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md AuditEntry; SC-001/SC-002
pred AuditCompletenessCheck {
    some Access
    // Every Access has exactly one audit entry
    all a: Access | one a.accAudit
    // Every AuditEntry is linked to exactly one Access (no orphan entries)
    all ae: AuditEntry | (one a: Access | a.accAudit = ae)
}
assert AuditCompletenessCheck { AuditCompletenessCheck }
check AuditCompletenessCheck for 5

// PATTERN: AppendOnly (notes)  ANCHOR: spec.md FR-012; data-model.md clinical_notes "no UPDATE/DELETE"; SC-007
pred AppendOnlyNotes {
    some ClinicalNote
    // Every note has a unique identity atom (Alloy enforces atom distinctness)
    // The structural invariant: only clinicians can author notes (no patient/compliance write path)
    all n: ClinicalNote | n.noteAuthor.userRole = RoleClinician
    // Only PostNote operations can produce notes
    all n: ClinicalNote |
        some a: Access |
            a.accOpKind = PostNote and a.accOutcome = Permitted and a.accRecord = n.noteRecord
}
assert AppendOnlyNotes { AppendOnlyNotes }
check AppendOnlyNotes for 5

// PATTERN: AppendOnly (audit entries)  ANCHOR: spec.md FR-015; data-model.md audit_entries "no UPDATE/DELETE"; SC-008
pred AppendOnlyAuditEntries {
    some AuditEntry
    // Every AuditEntry is the result of exactly one Access (bijection — no mutation)
    all ae: AuditEntry | (one a: Access | a.accAudit = ae)
    // Audit entries faithfully record the access outcome and accessor role
    all a: Access | a.accAudit.aeOutcome = a.accOutcome
}
assert AppendOnlyAuditEntries { AppendOnlyAuditEntries }
check AppendOnlyAuditEntries for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md AuditEntry fields; SC-001
pred AttributionCorrectnessCheck {
    some AuditEntry
    all a: Access |
        let ae = a.accAudit |
            ae.aeAccessor     = a.accUser          and
            ae.aeAccessorRole = a.accUser.userRole  and
            ae.aeOperation    = a.accOpKind         and
            ae.aeOutcome      = a.accOutcome
}
assert AttributionCorrectnessCheck { AttributionCorrectnessCheck }
check AttributionCorrectnessCheck for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md User.assigned_record_id
pred OwnershipBasedAccess {
    some a: Access | a.accUser.userRole = RolePatient
    // A patient with Permitted outcome on a record-scoped op
    // must be accessing their own assigned record
    all a: Access |
        (a.accUser.userRole = RolePatient and a.accOutcome = Permitted
         and a.accOpKind in (GetRecord + GetRecordAudit))
            implies a.accUser.assignedRecord = a.accRecord
    // A patient accessing any other record is denied
    all a: Access |
        (a.accUser.userRole = RolePatient
         and a.accUser.assignedRecord != a.accRecord
         and a.accOpKind in (GetRecord + PostNote + GetRecordAudit))
            implies a.accOutcome = Denied
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008; contracts/http-api.md byte-equivalent forbidden response; SC-003
pred NoInformationLeakage {
    some Access
    // For every denied access, the outcome is Denied regardless of whether the
    // record exists. Modelled as: the Denied outcome depends only on the
    // (Relationship × OperationKind) cell, not on record existence.
    // Two accesses by the same user with the same operation kind must have
    // identical outcomes when both are unauthorized (same relationship → same verdict).
    all disj a1, a2: Access |
        (a1.accUser = a2.accUser
         and a1.accOpKind = a2.accOpKind
         and a1.accRel = a2.accRel)
            implies a1.accOutcome = a2.accOutcome
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC PREDICATES
// ─────────────────────────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
    some Access
    all a: Access | one a.accUser
    all a: Access | a.accUser.userRole in (RoleClinician + RolePatient + RoleComplianceOfficer)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002; FR-003; data-model.md users CHECK
pred FR_002_ExactlyOneRoleAndPatientRecord {
    some User
    // Each user holds exactly one role (enforced by sig declaration)
    all u: User | one u.userRole
    // Patient users have exactly one assigned record; others have none
    all u: User |
        u.userRole = RolePatient implies (one u.assignedRecord)
    all u: User |
        u.userRole != RolePatient implies (no u.assignedRecord)
}
assert FR_002_ExactlyOneRoleAndPatientRecord { FR_002_ExactlyOneRoleAndPatientRecord }
check FR_002_ExactlyOneRoleAndPatientRecord for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004; data-model.md CareTeamMembership; SC-010
pred FR_004_CareTeamGating {
    some a: Access | a.accUser.userRole = RoleClinician
    // Clinician permitted on GetRecord only if in care team
    all a: Access |
        (a.accUser.userRole = RoleClinician
         and a.accOpKind in (GetRecord + PostNote + GetRecordAudit)
         and a.accOutcome = Permitted)
            implies a.accRel = CareTeamClinician
    // CareTeamClinician relationship requires an active membership row
    all a: Access |
        a.accRel = CareTeamClinician implies
            (some m: CareTeamMembership |
                m.ctClinician = a.accUser and m.ctRecord = a.accRecord)
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005; contracts/http-api.md permission table
pred FR_005_ClinicianAccessLogDenied {
    some a: Access | a.accUser.userRole = RoleClinician and a.accOpKind = GetAccessLog
    // No clinician may access the system-wide access log
    all a: Access |
        a.accUser.userRole = RoleClinician and a.accOpKind = GetAccessLog
            implies a.accOutcome = Denied
}
assert FR_005_ClinicianAccessLogDenied { FR_005_ClinicianAccessLogDenied }
check FR_005_ClinicianAccessLogDenied for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006; spec.md US3; data-model.md User.assigned_record_id
pred FR_006_PatientSelfAccessOnly {
    some a: Access | a.accUser.userRole = RolePatient
    // Patient cannot write notes on any record
    all a: Access |
        a.accUser.userRole = RolePatient and a.accOpKind = PostNote
            implies a.accOutcome = Denied
    // Patient cannot access the system-wide access log
    all a: Access |
        a.accUser.userRole = RolePatient and a.accOpKind = GetAccessLog
            implies a.accOutcome = Denied
    // Patient permitted on record-scoped ops only for their own record
    all a: Access |
        (a.accUser.userRole = RolePatient
         and a.accOutcome = Permitted
         and a.accOpKind in (GetRecord + GetRecordAudit))
            implies a.accUser.assignedRecord = a.accRecord
}
assert FR_006_PatientSelfAccessOnly { FR_006_PatientSelfAccessOnly }
check FR_006_PatientSelfAccessOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007; FR-019; spec.md US4; SC-006
pred FR_007_ComplianceContentBlindness {
    some a: Access | a.accUser.userRole = RoleComplianceOfficer
    // Compliance officer is denied GetRecord (clinical content) — no exceptions
    all a: Access |
        a.accUser.userRole = RoleComplianceOfficer and a.accOpKind = GetRecord
            implies a.accOutcome = Denied
    // Compliance officer is denied PostNote — no exceptions
    all a: Access |
        a.accUser.userRole = RoleComplianceOfficer and a.accOpKind = PostNote
            implies a.accOutcome = Denied
    // Compliance officer permitted operations never yield clinical note content
    // (modelled as: compliance-permitted outcomes are only on audit-related ops)
    all a: Access |
        (a.accUser.userRole = RoleComplianceOfficer and a.accOutcome = Permitted)
            implies a.accOpKind in (GetRecordAudit + GetAccessLog)
}
assert FR_007_ComplianceContentBlindness { FR_007_ComplianceContentBlindness }
check FR_007_ComplianceContentBlindness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008; contracts/http-api.md byte-equivalent forbidden response; SC-003
pred FR_008_ByteEquivalentDenial {
    some a: Access | a.accOutcome = Denied
    // Outcome is fully determined by (Relationship × OperationKind) — not by record existence.
    // Two accesses with the same relationship and operation kind always have the same outcome.
    all disj a1, a2: Access |
        (a1.accRel = a2.accRel and a1.accOpKind = a2.accOpKind)
            implies a1.accOutcome = a2.accOutcome
}
assert FR_008_ByteEquivalentDenial { FR_008_ByteEquivalentDenial }
check FR_008_ByteEquivalentDenial for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012; data-model.md clinical_notes "no UPDATE/DELETE"; SC-007
pred FR_012_NotesAppendOnly {
    some ClinicalNote
    // Only clinicians can author notes (structural impossibility for other roles)
    all n: ClinicalNote | n.noteAuthor.userRole = RoleClinician
    // A note can only exist if the author has/had care-team access to the record
    all n: ClinicalNote |
        some m: CareTeamMembership |
            m.ctClinician = n.noteAuthor and m.ctRecord = n.noteRecord
    // The only write operation kind is PostNote — no UpdateNote or DeleteNote exists
    all a: Access | a.accOpKind in (GetRecord + PostNote + GetRecordAudit + GetAccessLog)
}
assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013; spec.md SC-001 SC-002; data-model.md AuditEntry
pred FR_013_AuditCompletenessOneToOne {
    some Access
    // Every access has exactly one audit entry (no missing, no duplicate)
    all a: Access | one a.accAudit
    // No audit entry exists without a corresponding access
    all ae: AuditEntry | (one a: Access | a.accAudit = ae)
}
assert FR_013_AuditCompletenessOneToOne { FR_013_AuditCompletenessOneToOne }
check FR_013_AuditCompletenessOneToOne for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014; data-model.md AuditEntry CHECK (operation, outcome, note_id)
pred FR_014_AuditNoteIdLinkage {
    some AuditEntry
    // note_id present iff operation=append AND outcome=permitted
    all ae: AuditEntry |
        (ae.aeOperation = PostNote and ae.aeOutcome = Permitted) implies (one ae.aeNoteRef)
    all ae: AuditEntry |
        ae.aeOperation != PostNote implies (no ae.aeNoteRef)
    all ae: AuditEntry |
        (ae.aeOperation = PostNote and ae.aeOutcome = Denied) implies (no ae.aeNoteRef)
}
assert FR_014_AuditNoteIdLinkage { FR_014_AuditNoteIdLinkage }
check FR_014_AuditNoteIdLinkage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015; FR-017; spec.md SC-008; data-model.md audit_entries
pred FR_015_AuditImmutableRetained {
    some AuditEntry
    // Each AuditEntry belongs to exactly one Access — no mutation (no second "owner")
    all ae: AuditEntry | (one a: Access | a.accAudit = ae)
    // Audit entries faithfully preserve the outcome recorded at access time
    all a: Access | a.accAudit.aeOutcome = a.accOutcome
    all a: Access | a.accAudit.aeAccessorRole = a.accUser.userRole
}
assert FR_015_AuditImmutableRetained { FR_015_AuditImmutableRetained }
check FR_015_AuditImmutableRetained for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018; contracts/http-api.md GET /access-log authorisation
pred FR_018_AccessLogComplianceOnly {
    some a: Access | a.accOpKind = GetAccessLog
    // Access log endpoint is exclusive to compliance officers
    all a: Access |
        a.accOpKind = GetAccessLog and a.accOutcome = Permitted
            implies a.accUser.userRole = RoleComplianceOfficer
    // Clinicians and patients are always denied
    all a: Access |
        a.accUser.userRole in (RoleClinician + RolePatient) and a.accOpKind = GetAccessLog
            implies a.accOutcome = Denied
}
assert FR_018_AccessLogComplianceOnly { FR_018_AccessLogComplianceOnly }
check FR_018_AccessLogComplianceOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019; spec.md US4 SC-006; contracts/http-api.md content-blind shape
pred FR_019_ComplianceNoClinicContent {
    some a: Access | a.accUser.userRole = RoleComplianceOfficer and a.accOutcome = Permitted
    // A compliance-permitted access never touches GetRecord (which returns clinical content)
    all a: Access |
        (a.accUser.userRole = RoleComplianceOfficer and a.accOutcome = Permitted)
            implies a.accOpKind != GetRecord
    // A compliance-permitted access never touches PostNote
    all a: Access |
        (a.accUser.userRole = RoleComplianceOfficer and a.accOutcome = Permitted)
            implies a.accOpKind != PostNote
    // Notes are never linked from compliance-officer audit entries
    all a: Access |
        a.accUser.userRole = RoleComplianceOfficer
            implies (no a.accAudit.aeNoteRef)
}
assert FR_019_ComplianceNoClinicContent { FR_019_ComplianceNoClinicContent }
check FR_019_ComplianceNoClinicContent for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_PatientAuthorsNote { some n: ClinicalNote, u: User | n.noteAuthor = u and u.userRole = RolePatient }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
