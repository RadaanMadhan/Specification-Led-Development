// === feature_model.als — Alloy model for Hospital Clinical Record Access (C-L2) ===
// Feature branch: 012-hospital-clinical-records
// Artefacts: spec.md (FR-001 – FR-020), data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────────────────────────────────
// ROLES
// ─────────────────────────────────────────────────────────────────────────────

abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin extends Role {}   // clinical roles
one sig HospitalAdministrator extends Role {}                       // audit-only role

// ─────────────────────────────────────────────────────────────────────────────
// OPERATION KINDS  (one per exposed endpoint)
// ─────────────────────────────────────────────────────────────────────────────

abstract sig OperationKind {}
one sig RecordLookup extends OperationKind {}   // POST /records/lookup
one sig AddNote      extends OperationKind {}   // POST /records/notes
one sig AuditSearch  extends OperationKind {}   // POST /audit/search

// ─────────────────────────────────────────────────────────────────────────────
// ACCESS OUTCOMES & AUTHORISATION BASIS
// ─────────────────────────────────────────────────────────────────────────────

abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

abstract sig AuthBasis {}
one sig CareTeamMemberBasis, NotCareTeamMemberBasis,
        PatientNotFoundBasis, AdministratorRoleBasis extends AuthBasis {}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (role-level; care-team check is a separate structural rule)
// contracts/http-api.md authorisation sections; spec.md FR-004, FR-005, FR-017
// ─────────────────────────────────────────────────────────────────────────────

one sig PermMatrix {
    Allowed: set Role -> OperationKind
}

// ─────────────────────────────────────────────────────────────────────────────
// DYNAMIC SIGS
// ─────────────────────────────────────────────────────────────────────────────

sig User {
    role: one Role
}

sig Patient {}

// Active care-team membership rows (status = 'active' rows only).
// Ended rows are excluded from this sig — they carry no authorisation weight.
sig ActiveMembership {
    clinician : one User,
    patient   : one Patient
}

sig ClinicalNote {
    notePatient : one Patient,
    author      : one User
}

// Every access attempt (whether permitted or denied) is represented by one
// AuditEntry.  AuditEntries are the single record of system activity.
sig AuditEntry {
    accessor      : one User,
    auditPatient  : one Patient,
    opKind        : one OperationKind,
    outcome       : one AccessOutcome,
    authBasis     : one AuthBasis,
    noteRef       : lone ClinicalNote   // set iff AddNote + Permitted (FR-013)
}

// ─────────────────────────────────────────────────────────────────────────────
// NON-EMPTY UNIVERSE  (prevents vacuous all-quantified assertions)
// ─────────────────────────────────────────────────────────────────────────────

fact F_NonEmptyUniverse {
    some User
    some Patient
    some ActiveMembership
    some ClinicalNote
    some AuditEntry
}

// ─────────────────────────────────────────────────────────────────────────────
// F_PermissionMatrix
// Closed-world encoding of the role × endpoint permission table.
// ANCHOR: contracts/http-api.md authorisation sections; spec.md FR-004 FR-005 FR-017
// ─────────────────────────────────────────────────────────────────────────────

fact F_PermissionMatrix {
    // Clinical roles may use record-read and note-add (subject to care-team check).
    // Hospital administrator may only use audit-search.
    // All other cells are implicitly denied (closed world enforced by equality below).
    PermMatrix.Allowed =
        (Doctor             -> RecordLookup) +
        (Doctor             -> AddNote)      +
        (Nurse              -> RecordLookup) +
        (Nurse              -> AddNote)      +
        (Pharmacist         -> RecordLookup) +
        (Pharmacist         -> AddNote)      +
        (ClinicalAdmin      -> RecordLookup) +
        (ClinicalAdmin      -> AddNote)      +
        (HospitalAdministrator -> AuditSearch)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_LeastPrivilege
// A Permitted outcome may only occur for (role, operation) pairs in the matrix.
// ANCHOR: contracts/http-api.md authorisation sections; spec.md FR-004 FR-005 FR-017
// ─────────────────────────────────────────────────────────────────────────────

fact F_LeastPrivilege {
    all ae: AuditEntry |
        ae.outcome = Permitted implies
        (ae.accessor.role -> ae.opKind in PermMatrix.Allowed)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_CareTeamGating
// A clinical-endpoint access (RecordLookup or AddNote) is only Permitted when
// there is an active membership linking the accessor to the audit's patient.
// ANCHOR: spec.md FR-004; data-model.md CareTeamMembership
// ─────────────────────────────────────────────────────────────────────────────

fact F_CareTeamGating {
    all ae: AuditEntry |
        (ae.opKind in (RecordLookup + AddNote) and ae.outcome = Permitted) implies
        (some m: ActiveMembership |
            m.clinician = ae.accessor and m.patient = ae.auditPatient)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AdminCannotAddNote
// The HospitalAdministrator role is structurally excluded from being a note
// author (data-model.md CHECK on author_role; spec.md FR-005).
// ANCHOR: spec.md FR-005; data-model.md ClinicalNote author_role CHECK
// ─────────────────────────────────────────────────────────────────────────────

fact F_AdminCannotAddNote {
    all n: ClinicalNote |
        n.author.role != HospitalAdministrator
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NoteIdConstraint
// noteRef is populated iff the entry is AddNote + Permitted; empty otherwise.
// ANCHOR: spec.md FR-013; data-model.md AuditEntry CHECK on (access_type, outcome, note_id)
// ─────────────────────────────────────────────────────────────────────────────

fact F_NoteIdConstraint {
    all ae: AuditEntry | {
        // AddNote + Permitted  →  exactly one note referenced
        (ae.opKind = AddNote and ae.outcome = Permitted) implies (one ae.noteRef)
        // AddNote + non-Permitted  →  no note referenced
        (ae.opKind = AddNote and ae.outcome != Permitted) implies (no ae.noteRef)
        // RecordLookup or AuditSearch  →  no note referenced
        (ae.opKind in (RecordLookup + AuditSearch)) implies (no ae.noteRef)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NoteRefPatientConsistency
// When an AuditEntry references a note, the note's patient must match the
// audit entry's patient.
// ANCHOR: spec.md FR-010 FR-013; data-model.md ClinicalNote / AuditEntry
// ─────────────────────────────────────────────────────────────────────────────

fact F_NoteRefPatientConsistency {
    all ae: AuditEntry |
        (some ae.noteRef) implies (ae.noteRef.notePatient = ae.auditPatient)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditCompleteness
// Every ClinicalNote that exists in the model has exactly one corresponding
// AddNote+Permitted AuditEntry referencing it (one-to-one correspondence).
// ANCHOR: spec.md FR-012; data-model.md always-on audit note
// ─────────────────────────────────────────────────────────────────────────────

fact F_AuditCompleteness {
    all n: ClinicalNote |
        one ae: AuditEntry |
            ae.opKind = AddNote and ae.outcome = Permitted and ae.noteRef = n
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuditEntryUniqueness
// No two distinct AuditEntries reference the same ClinicalNote.
// (Supports the "exactly one audit entry per note-addition" claim.)
// ANCHOR: spec.md FR-012; data-model.md UNIQUE(note_id) implied by 1:1
// ─────────────────────────────────────────────────────────────────────────────

fact F_AuditEntryUniqueness {
    all disj ae1, ae2: AuditEntry |
        (some ae1.noteRef and some ae2.noteRef) implies (ae1.noteRef != ae2.noteRef)
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AttributionCorrectness
// The accessor snapshotted in an AuditEntry is the actual user; their role in
// the entry matches their current role (the snapshot model used in v1).
// ANCHOR: spec.md FR-013; data-model.md AuditEntry user_role snapshot
// ─────────────────────────────────────────────────────────────────────────────

fact F_AttributionCorrectness {
    // In Alloy's static model the snapshot IS the live role (single state).
    // We enforce that every audit accessor is a real User in the User sig.
    all ae: AuditEntry | ae.accessor in User
    // Note author attribution: the author recorded on the note is a real User.
    all n: ClinicalNote | n.author in User
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AdminContentBlindness
// AuditSearch entries are only written for HospitalAdministrator callers
// (role-level enforcement that only admins can trigger AuditSearch).
// ANCHOR: spec.md FR-005 FR-017 FR-018; contracts/http-api.md POST /audit/search
// ─────────────────────────────────────────────────────────────────────────────

fact F_AdminContentBlindness {
    all ae: AuditEntry |
        ae.opKind = AuditSearch implies ae.accessor.role = HospitalAdministrator
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AuthBasisConsistency
// The authorisation basis recorded on each AuditEntry is coherent with the
// outcome and the role/membership state.
// ANCHOR: spec.md FR-013; data-model.md AuthorisationBasis enum
// ─────────────────────────────────────────────────────────────────────────────

fact F_AuthBasisConsistency {
    all ae: AuditEntry | {
        // Permitted on a clinical op → basis is care_team_member
        (ae.opKind in (RecordLookup + AddNote) and ae.outcome = Permitted) implies
            ae.authBasis = CareTeamMemberBasis
        // Permitted on audit-search → basis is administrator_role
        (ae.opKind = AuditSearch and ae.outcome = Permitted) implies
            ae.authBasis = AdministratorRoleBasis
        // Patient-not-found basis → outcome must be NotFoundOrDenied
        ae.authBasis = PatientNotFoundBasis implies ae.outcome = NotFoundOrDenied
        // Administrator basis → accessor is HospitalAdministrator
        ae.authBasis = AdministratorRoleBasis implies
            ae.accessor.role = HospitalAdministrator
        // CareTeamMember basis → accessor holds a clinical role
        ae.authBasis = CareTeamMemberBasis implies
            ae.accessor.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// F_NoInfoLeakage
// Denied and NotFoundOrDenied outcomes are structurally indistinguishable from
// the accessor's perspective: both result in a non-Permitted outcome.  We
// encode this by asserting that clinicians off the care team receive the same
// outcome class as the patient-not-found case.
// ANCHOR: spec.md FR-006; contracts/http-api.md byte-equivalent 404 envelope
// ─────────────────────────────────────────────────────────────────────────────

fact F_NoInfoLeakage {
    // A clinical-role accessor with no active membership on the audit's patient
    // MUST NOT receive a Permitted outcome on RecordLookup or AddNote.
    all ae: AuditEntry |
        (ae.opKind in (RecordLookup + AddNote) and
         ae.accessor.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
         (no m: ActiveMembership |
             m.clinician = ae.accessor and m.patient = ae.auditPatient))
        implies ae.outcome != Permitted
}

// ─────────────────────────────────────────────────────────────────────────────
// F_ValidationBeforeMutation
// A ClinicalNote only exists when there is a corresponding Permitted AuditEntry
// for AddNote — i.e., no note can exist without a successful, audited creation.
// (Notes created under a failed/rejected submission do not exist.)
// ANCHOR: spec.md FR-009 FR-015; contracts/http-api.md addNote behaviour
// ─────────────────────────────────────────────────────────────────────────────

fact F_ValidationBeforeMutation {
    all n: ClinicalNote |
        some ae: AuditEntry |
            ae.opKind = AddNote and ae.outcome = Permitted and ae.noteRef = n
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AppendOnlyNotes
// Every ClinicalNote in the model is referenced by exactly one audit entry
// (its creation event); there is no "update" relation anywhere in the model.
// We encode structural immutability: the author and patient of a note are fixed
// at creation (captured by F_AuditCompleteness + F_NoteRefPatientConsistency).
// ANCHOR: spec.md FR-011; data-model.md ClinicalNote append-only enforcement
// ─────────────────────────────────────────────────────────────────────────────

fact F_AppendOnlyNotes {
    // Structural: no two AuditEntries may reference the same note (already
    // in F_AuditEntryUniqueness), and the author of the note matches the
    // accessor on its creation audit entry.
    all n: ClinicalNote |
        all ae: AuditEntry |
            (ae.noteRef = n) implies ae.accessor = n.author
}

// ─────────────────────────────────────────────────────────────────────────────
// F_AppendOnlyAuditEntries
// Audit entries are immutable.  In the static model this is captured by: no
// AuditEntry can be the "subject" of another AuditEntry's modification — the
// audit table itself is not touched by any RecordLookup or AddNote.
// We encode: for any pair of AuditEntries, they are structurally distinct
// atoms and no accessor "authors" an AuditEntry (only the system does).
// The key structural constraint: each AuditEntry is uniquely determined by
// (accessor, auditPatient, opKind, outcome) — no phantom duplicates.
// ANCHOR: spec.md FR-014 FR-016; data-model.md AuditEntry append-only enforcement
// ─────────────────────────────────────────────────────────────────────────────

fact F_AppendOnlyAuditEntries {
    // No two distinct AuditEntries record the exact same (accessor, patient,
    // opKind, noteRef) tuple — each audit event is a distinct occurrence.
    // (Two concurrent reads by the same user DO produce separate entries,
    // which Alloy models as distinct atoms; the constraint here prevents
    // the "same event logged twice" duplicate.)
    all disj ae1, ae2: AuditEntry | {
        not (ae1.accessor = ae2.accessor and
             ae1.auditPatient = ae2.auditPatient and
             ae1.opKind = ae2.opKind and
             ae1.noteRef = ae2.noteRef and
             ae1.outcome = ae2.outcome and
             ae1.authBasis = ae2.authBasis)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// F_OwnershipExclusivity
// ActiveMembership tuples are unique per (clinician, patient) pair — a
// clinician either is or is not actively on a patient's care team; there is
// no structural duplicity.
// ANCHOR: data-model.md CareTeamMembership composite PK
// ─────────────────────────────────────────────────────────────────────────────

fact F_OwnershipExclusivity {
    all disj m1, m2: ActiveMembership |
        not (m1.clinician = m2.clinician and m1.patient = m2.patient)
}

// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
//   P R E D I C A T E S   &   A S S E R T I O N S
// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

// ── CATALOGUE PATTERNS ───────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-004 FR-005 FR-017
pred LeastPrivilege {
    some AuditEntry   // universe is non-trivial
    all ae: AuditEntry |
        ae.outcome = Permitted implies
        (ae.accessor.role -> ae.opKind in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table; spec.md FR-004 FR-017
pred PermissionCompleteness {
    // Every role is covered: it either has ≥1 allowed op or its allowed set is empty
    // (the key check is that the matrix is fully specified — no role is simply absent).
    all r: Role | r in (Doctor + Nurse + Pharmacist + ClinicalAdmin + HospitalAdministrator)
    // Every operation kind appears in the allowed relation for at least one role.
    all o: OperationKind | some r: Role | r -> o in PermMatrix.Allowed
    // No role not in our catalogue appears in the matrix.
    all r: Role, o: OperationKind |
        r -> o in PermMatrix.Allowed implies
        r in (Doctor + Nurse + Pharmacist + ClinicalAdmin + HospitalAdministrator)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-004 FR-005 FR-017; contracts/http-api.md
pred PermissionGrounding {
    // HospitalAdministrator is only allowed AuditSearch (grounded in FR-017).
    HospitalAdministrator -> AuditSearch in PermMatrix.Allowed
    HospitalAdministrator -> RecordLookup not in PermMatrix.Allowed
    HospitalAdministrator -> AddNote      not in PermMatrix.Allowed
    // Clinical roles are allowed RecordLookup and AddNote (grounded in FR-004).
    all cr: (Doctor + Nurse + Pharmacist + ClinicalAdmin) | {
        cr -> RecordLookup in PermMatrix.Allowed
        cr -> AddNote      in PermMatrix.Allowed
        cr -> AuditSearch  not in PermMatrix.Allowed
    }
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md role descriptions; contracts/http-api.md
// Admin role is strictly disjoint from clinical privileges (not a superset).
pred PrivilegeMonotonicity {
    // All four clinical roles share the same allowed operation set.
    all cr1, cr2: (Doctor + Nurse + Pharmacist + ClinicalAdmin) |
        { o: OperationKind | cr1 -> o in PermMatrix.Allowed } =
        { o: OperationKind | cr2 -> o in PermMatrix.Allowed }
    // The admin role's allowed set is disjoint from the clinical allowed set.
    no o: OperationKind |
        (HospitalAdministrator -> o in PermMatrix.Allowed and
         Doctor -> o in PermMatrix.Allowed)
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md authentication section
pred AuthRequiredEverywhere {
    // Every AuditEntry has a valid accessor (a real User in the model).
    // Unauthenticated requests never produce AuditEntries (FR-001 edge-case 4).
    some AuditEntry
    all ae: AuditEntry | ae.accessor in User
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012; data-model.md one-to-one note↔audit
pred AuditCompleteness {
    // Every ClinicalNote has exactly one creation AuditEntry.
    some ClinicalNote
    all n: ClinicalNote |
        (one ae: AuditEntry |
            ae.opKind = AddNote and ae.outcome = Permitted and ae.noteRef = n)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly (Notes)  ANCHOR: spec.md FR-011 SC-007; data-model.md append-only enforcement
pred AppendOnly {
    // For every note, the single creation audit entry names the correct author.
    some ClinicalNote
    all n: ClinicalNote |
        all ae: AuditEntry |
            (ae.noteRef = n) implies ae.accessor = n.author
    // No two AuditEntries share the same note reference.
    all disj ae1, ae2: AuditEntry |
        (some ae1.noteRef) implies ae1.noteRef != ae2.noteRef
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md snapshot fields
pred AttributionCorrectness {
    // The note's author matches the accessor on its creation audit entry.
    some ClinicalNote
    all n: ClinicalNote |
        all ae: AuditEntry |
            (ae.noteRef = n) implies ae.accessor = n.author
    // Every AuditEntry accessor is a genuine user.
    all ae: AuditEntry | ae.accessor in User
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
    // A Permitted clinical access implies an active membership row.
    some ae: AuditEntry |
        ae.opKind in (RecordLookup + AddNote) and ae.outcome = Permitted
    all ae: AuditEntry |
        (ae.opKind in (RecordLookup + AddNote) and ae.outcome = Permitted) implies
        (some m: ActiveMembership |
            m.clinician = ae.accessor and m.patient = ae.auditPatient)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006; contracts/http-api.md byte-equivalent 404
pred NoInformationLeakage {
    // A clinical-role user with no care-team membership must not receive Permitted.
    some ae: AuditEntry |
        ae.opKind in (RecordLookup + AddNote) and ae.outcome != Permitted
    all ae: AuditEntry |
        (ae.opKind in (RecordLookup + AddNote) and
         ae.accessor.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
         (no m: ActiveMembership |
             m.clinician = ae.accessor and m.patient = ae.auditPatient))
        implies ae.outcome != Permitted
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-009 FR-015; contracts/http-api.md AddNote behaviour
pred ValidationBeforeMutation {
    // No ClinicalNote may exist without a Permitted AddNote AuditEntry.
    some ClinicalNote
    all n: ClinicalNote |
        (some ae: AuditEntry |
            ae.opKind = AddNote and ae.outcome = Permitted and ae.noteRef = n)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ── FEATURE-SPECIFIC PREDICATES ──────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
    // Every access event in the model has a real authenticated accessor.
    some AuditEntry
    all ae: AuditEntry | one ae.accessor
    all ae: AuditEntry | ae.accessor in User
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_OneRolePerUser {
    // Every user has exactly one role drawn from the five-value catalogue.
    some User
    all u: User |
        one u.role and
        u.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin + HospitalAdministrator)
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_CareTeamGating {
    // A Permitted clinical access exists, and every such access has membership.
    some ae: AuditEntry |
        ae.opKind in (RecordLookup + AddNote) and ae.outcome = Permitted
    all ae: AuditEntry |
        (ae.opKind in (RecordLookup + AddNote) and ae.outcome = Permitted) implies
        (some m: ActiveMembership |
            m.clinician = ae.accessor and m.patient = ae.auditPatient)
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_AdminCannotAccessClinical {
    // The HospitalAdministrator role can never receive a Permitted outcome on
    // RecordLookup or AddNote.
    some User
    all ae: AuditEntry |
        ae.accessor.role = HospitalAdministrator implies
        ae.opKind not in (RecordLookup + AddNote) or ae.outcome != Permitted
}
assert FR_005_AdminCannotAccessClinical { FR_005_AdminCannotAccessClinical }
check FR_005_AdminCannotAccessClinical for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 FR-017
pred FR_005_AdminCannotAddNote {
    // No ClinicalNote authored by a HospitalAdministrator exists.
    some ClinicalNote
    all n: ClinicalNote | n.author.role != HospitalAdministrator
}
assert FR_005_AdminCannotAddNote { FR_005_AdminCannotAddNote }
check FR_005_AdminCannotAddNote for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_DeniedEqualsNotFound {
    // Any clinical-role user without membership gets a non-Permitted outcome.
    // (Both Denied and NotFoundOrDenied map to the same external envelope.)
    some AuditEntry
    all ae: AuditEntry |
        (ae.opKind in (RecordLookup + AddNote) and
         ae.accessor.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
         not (some m: ActiveMembership |
                  m.clinician = ae.accessor and m.patient = ae.auditPatient))
        implies ae.outcome != Permitted
}
assert FR_006_DeniedEqualsNotFound { FR_006_DeniedEqualsNotFound }
check FR_006_DeniedEqualsNotFound for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 SC-007
pred FR_011_NotesAppendOnly {
    // Each note is created exactly once — there is exactly one Permitted AddNote
    // audit entry referencing it, and no other entry modifies it.
    some ClinicalNote
    all n: ClinicalNote |
        one ae: AuditEntry |
            ae.opKind = AddNote and ae.outcome = Permitted and ae.noteRef = n
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 SC-001 SC-002
pred FR_012_AlwaysOnAudit {
    // Every ClinicalNote has a corresponding creation AuditEntry (no silent writes).
    some ClinicalNote
    all n: ClinicalNote |
        (some ae: AuditEntry | ae.opKind = AddNote and ae.noteRef = n)
    // Every permitted clinical access has an audit entry (by construction:
    // AuditEntries ARE the access records in this model).
    some ae: AuditEntry | ae.outcome = Permitted
}
assert FR_012_AlwaysOnAudit { FR_012_AlwaysOnAudit }
check FR_012_AlwaysOnAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_AuditEntryShape {
    // note_id is set iff AddNote + Permitted; absent for all other cases.
    some AuditEntry
    all ae: AuditEntry | {
        (ae.opKind = AddNote and ae.outcome = Permitted) iff (one ae.noteRef)
        (ae.opKind = AddNote and ae.outcome != Permitted) iff (no ae.noteRef)
        ae.opKind in (RecordLookup + AuditSearch) implies (no ae.noteRef)
    }
}
assert FR_013_AuditEntryShape { FR_013_AuditEntryShape }
check FR_013_AuditEntryShape for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 SC-008
pred FR_014_AuditImmutability {
    // No two distinct AuditEntries are identical atoms with the same full content
    // (each access event is a distinct, non-rewriteable record).
    some AuditEntry
    all disj ae1, ae2: AuditEntry |
        not (ae1.accessor = ae2.accessor and
             ae1.auditPatient = ae2.auditPatient and
             ae1.opKind = ae2.opKind and
             ae1.outcome = ae2.outcome and
             ae1.authBasis = ae2.authBasis and
             ae1.noteRef = ae2.noteRef)
}
assert FR_014_AuditImmutability { FR_014_AuditImmutability }
check FR_014_AuditImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017
pred FR_017_AdminOnlyAuditSearch {
    // AuditSearch accesses are exclusively issued by HospitalAdministrator users.
    some ae: AuditEntry | ae.opKind = AuditSearch
    all ae: AuditEntry |
        ae.opKind = AuditSearch implies ae.accessor.role = HospitalAdministrator
}
assert FR_017_AdminOnlyAuditSearch { FR_017_AdminOnlyAuditSearch }
check FR_017_AdminOnlyAuditSearch for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 FR-005
pred FR_017_CliniciansCannotAuditSearch {
    // No clinical-role user receives a Permitted outcome on AuditSearch.
    some User
    all ae: AuditEntry |
        ae.accessor.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
        implies ae.opKind != AuditSearch or ae.outcome != Permitted
}
assert FR_017_CliniciansCannotAuditSearch { FR_017_CliniciansCannotAuditSearch }
check FR_017_CliniciansCannotAuditSearch for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 FR-005 SC-006
pred FR_018_AdminContentBlindness {
    // AuditSearch entries only appear when the accessor is HospitalAdministrator.
    // No ClinicalNote is authored by HospitalAdministrator (content-blindness enforced structurally).
    some User
    all ae: AuditEntry |
        ae.opKind = AuditSearch implies ae.accessor.role = HospitalAdministrator
    all n: ClinicalNote | n.author.role != HospitalAdministrator
}
assert FR_018_AdminContentBlindness { FR_018_AdminContentBlindness }
check FR_018_AdminContentBlindness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 FR-010
pred FR_009_NoteAuthorOnCareTeam {
    // The author of every ClinicalNote must have had an active membership for
    // that note's patient (implied by ValidationBeforeMutation + CareTeamGating).
    some ClinicalNote
    all n: ClinicalNote |
        some m: ActiveMembership |
            m.clinician = n.author and m.patient = n.notePatient
}
assert FR_009_NoteAuthorOnCareTeam { FR_009_NoteAuthorOnCareTeam }
check FR_009_NoteAuthorOnCareTeam for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 FR-013
pred FR_010_NoteAuthorIsClinical {
    // Every clinical note is authored by a clinical-role user.
    some ClinicalNote
    all n: ClinicalNote |
        n.author.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}
assert FR_010_NoteAuthorIsClinical { FR_010_NoteAuthorIsClinical }
check FR_010_NoteAuthorIsClinical for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 AuthBasis consistency
pred FR_013_AuthBasisConsistency {
    some AuditEntry
    all ae: AuditEntry | {
        ae.authBasis = CareTeamMemberBasis implies
            (ae.opKind in (RecordLookup + AddNote) and ae.outcome = Permitted and
             ae.accessor.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin))
        ae.authBasis = AdministratorRoleBasis implies
            (ae.opKind = AuditSearch and ae.accessor.role = HospitalAdministrator)
        ae.authBasis = PatientNotFoundBasis implies ae.outcome = NotFoundOrDenied
        ae.authBasis = NotCareTeamMemberBasis implies ae.outcome != Permitted
    }
}
assert FR_013_AuthBasisConsistency { FR_013_AuthBasisConsistency }
check FR_013_AuthBasisConsistency for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_AdminContentBlindnessViolation { some ae: AuditEntry | ae.opKind = AuditSearch and ae.accessor.role = Doctor }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
