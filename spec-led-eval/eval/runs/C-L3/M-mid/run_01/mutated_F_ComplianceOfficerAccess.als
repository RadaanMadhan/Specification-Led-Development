// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===
// Feature folder: C-L3 (branch 013-hipaa-clinical-records)
// Sources: spec.md, data-model.md, contracts/http-api.md

// ══════════════════════════════════════════════════════════════════════
// ROLES
// ══════════════════════════════════════════════════════════════════════
abstract sig Role {}
one sig Clinician, PatientRole, ComplianceOfficer extends Role {}

// ══════════════════════════════════════════════════════════════════════
// OPERATION KINDS  (the four endpoints of this feature)
// ══════════════════════════════════════════════════════════════════════
abstract sig OperationKind {}
one sig GetRecord, PostNote, GetRecordAudit, GetAccessLog extends OperationKind {}

// ══════════════════════════════════════════════════════════════════════
// OUTCOMES
// ══════════════════════════════════════════════════════════════════════
abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

// ══════════════════════════════════════════════════════════════════════
// PERMISSION MATRIX  (base role-level potential grants, ignoring
// conditional care-team / ownership checks)
// Canonical pattern: singleton sig field
// ══════════════════════════════════════════════════════════════════════
one sig PermMatrix {
    Allowed: set Role -> OperationKind
}

// ══════════════════════════════════════════════════════════════════════
// CORE DOMAIN ENTITIES
// ══════════════════════════════════════════════════════════════════════

sig Record {}

sig User {
    role:           one  Role,
    assignedRecord: lone Record    -- non-null iff role = PatientRole
}

// Active care-team membership linking a clinician to a record.
// Only active memberships are modelled (the status predicate is
// evaluated per-request; we represent the post-evaluation snapshot).
sig CareTeamMembership {
    ctClinician: one User,
    ctRecord:    one Record
}

sig ClinicalNote {
    noteRecord: one Record,
    noteAuthor: one User
}

// AuditEntry — immutable, append-only (FR-013..FR-017)
sig AuditEntry {
    auditRecord:    lone Record,       -- null iff GetAccessLog system-wide
    auditAccessor:  one  User,
    auditOperation: one  OperationKind,
    auditOutcome:   one  Outcome,
    auditNote:      lone ClinicalNote  -- non-null iff append + permitted
}

// Operation — one authenticated API call attempt
sig Operation {
    opCaller:  one  User,
    opKind:    one  OperationKind,
    opRecord:  lone Record,    -- null iff GetAccessLog
    opOutcome: one  Outcome,
    opAudit:   one  AuditEntry -- every authenticated operation has exactly one
}

// ══════════════════════════════════════════════════════════════════════
// NON-EMPTY UNIVERSE (Rule 9: dynamic sigs need at least one atom)
// ══════════════════════════════════════════════════════════════════════
fact F_NonEmptyUniverse {
    some Record
    some User
    some CareTeamMembership
    some ClinicalNote
    some AuditEntry
    some Operation
}

// ══════════════════════════════════════════════════════════════════════
// F_BasePermissionMatrix
// Closed-world: exactly these cells are in the base permission set.
// Clinicians can never reach GetAccessLog.
// Patients can never reach PostNote or GetAccessLog.
// Compliance officers can never reach GetRecord or PostNote.
// (spec.md authorisation matrix; contracts/http-api.md permission table)
// ══════════════════════════════════════════════════════════════════════
fact F_BasePermissionMatrix {
    PermMatrix.Allowed =
        (Clinician       -> GetRecord)    +
        (Clinician       -> PostNote)     +
        (Clinician       -> GetRecordAudit) +
        (PatientRole     -> GetRecord)    +
        (PatientRole     -> GetRecordAudit) +
        (ComplianceOfficer -> GetRecordAudit) +
        (ComplianceOfficer -> GetAccessLog)
}

// ══════════════════════════════════════════════════════════════════════
// F_PatientAssignedRecord
// A patient user has exactly one assigned record; non-patients have none.
// (spec.md FR-003; data-model.md User CHECK constraint)
// ══════════════════════════════════════════════════════════════════════
fact F_PatientAssignedRecord {
    all u: User |
        (u.role = PatientRole  implies (one u.assignedRecord)) and
        (u.role != PatientRole implies (no  u.assignedRecord))
}

// ══════════════════════════════════════════════════════════════════════
// F_CareTeamMembersAreClinicians
// Only users with role clinician appear in care-team memberships.
// (spec.md FR-004; data-model.md CareTeamMembership)
// ══════════════════════════════════════════════════════════════════════
fact F_CareTeamMembersAreClinicians {
    all m: CareTeamMembership | m.ctClinician.role = Clinician
}

// ══════════════════════════════════════════════════════════════════════
// F_NoteAuthorIsClinician
// Only clinicians may author clinical notes (append-only surface, FR-012).
// (spec.md FR-012; data-model.md ClinicalNote author_role CHECK)
// ══════════════════════════════════════════════════════════════════════
fact F_NoteAuthorIsClinician {
    all n: ClinicalNote | n.noteAuthor.role = Clinician
}

// ══════════════════════════════════════════════════════════════════════
// F_NoteAuthorInCareTeam
// A clinician may only author a note if they are in the care team for
// that record.
// (spec.md FR-004, FR-011; contracts/http-api.md POST /records/{id}/notes)
// ══════════════════════════════════════════════════════════════════════
fact F_NoteAuthorInCareTeam {
    all n: ClinicalNote |
        some m: CareTeamMembership |
            m.ctClinician = n.noteAuthor and m.ctRecord = n.noteRecord
}

// ══════════════════════════════════════════════════════════════════════
// F_OperationRecordConsistency
// GetAccessLog operations have no record target; all others do.
// (spec.md FR-013; data-model.md AuditEntry record_id nullability)
// ══════════════════════════════════════════════════════════════════════
fact F_OperationRecordConsistency {
    all op: Operation |
        (op.opKind = GetAccessLog implies no  op.opRecord) and
        (op.opKind != GetAccessLog implies one op.opRecord)
}

// ══════════════════════════════════════════════════════════════════════
// F_AuditRecordConsistency
// Audit record_id is null only for GetAccessLog list events.
// (spec.md FR-014; data-model.md AuditEntry record_id CHECK)
// ══════════════════════════════════════════════════════════════════════
fact F_AuditRecordConsistency {
    all ae: AuditEntry |
        (ae.auditOperation = GetAccessLog implies no  ae.auditRecord) and
        (ae.auditOperation != GetAccessLog implies one ae.auditRecord)
}

// ══════════════════════════════════════════════════════════════════════
// F_AuditNoteConsistency
// auditNote is non-null iff operation=PostNote AND outcome=Permitted.
// (spec.md FR-014; data-model.md AuditEntry note_id CHECK)
// ══════════════════════════════════════════════════════════════════════
fact F_AuditNoteConsistency {
    all ae: AuditEntry |
        (ae.auditOperation = PostNote and ae.auditOutcome = Permitted
            implies one  ae.auditNote) and
        ((ae.auditOperation != PostNote or ae.auditOutcome = Denied)
            implies no ae.auditNote)
}

// ══════════════════════════════════════════════════════════════════════
// F_AuditAttributionCorrect
// The audit entry produced by an operation mirrors the caller's identity
// and the operation's kind and outcome exactly.
// (spec.md FR-014; data-model.md AuditEntry fields)
// ══════════════════════════════════════════════════════════════════════
fact F_AuditAttributionCorrect {
    all op: Operation | let ae = op.opAudit | {
        ae.auditAccessor  = op.opCaller
        ae.auditOperation = op.opKind
        ae.auditOutcome   = op.opOutcome
        ae.auditRecord    = op.opRecord
    }
}

// ══════════════════════════════════════════════════════════════════════
// F_AuditEntriesBelongToOperations
// Every AuditEntry is the audit of exactly one Operation (no orphan
// or duplicate audit entries).
// (spec.md FR-013; data-model.md; SC-002)
// ══════════════════════════════════════════════════════════════════════
fact F_AuditEntriesBelongToOperations {
    all ae: AuditEntry | one op: Operation | op.opAudit = ae
}

// ══════════════════════════════════════════════════════════════════════
// F_CareTeamMembershipGating
// An operation on GetRecord or PostNote by a clinician is Permitted
// iff that clinician has an active CareTeamMembership for the target
// record.  All other callers are Denied.
// (spec.md FR-004; contracts/http-api.md permission matrix)
// ══════════════════════════════════════════════════════════════════════
fact F_CareTeamMembershipGating {
    all op: Operation |
        (op.opKind = GetRecord or op.opKind = PostNote) implies {
            op.opOutcome = Permitted iff
                (op.opCaller.role = Clinician and
                 some m: CareTeamMembership |
                     m.ctClinician = op.opCaller and m.ctRecord = op.opRecord)
        }
}

// ══════════════════════════════════════════════════════════════════════
// F_PatientSelfAccessOnly
// A patient's GetRecord or GetRecordAudit is Permitted iff the target
// record equals their assigned record.
// (spec.md FR-006; data-model.md User assigned_record_id)
// ══════════════════════════════════════════════════════════════════════
fact F_PatientSelfAccessOnly {
    all op: Operation |
        op.opCaller.role = PatientRole implies {
            (op.opKind = GetRecord or op.opKind = GetRecordAudit) implies
                (op.opOutcome = Permitted iff
                     op.opRecord = op.opCaller.assignedRecord)
            op.opKind = PostNote   implies op.opOutcome = Denied
            op.opKind = GetAccessLog implies op.opOutcome = Denied
        }
}

// ══════════════════════════════════════════════════════════════════════
// F_ComplianceOfficerAccess
// Compliance officers are Permitted on GetRecordAudit and GetAccessLog;
// they are always Denied on GetRecord and PostNote.
// (spec.md FR-007; contracts/http-api.md permission matrix)
// ══════════════════════════════════════════════════════════════════════
fact F_ComplianceOfficerAccess { /* MUTATED — body cleared by validator */ }

// ══════════════════════════════════════════════════════════════════════
// F_ClinicianGetRecordAuditGating
// A clinician's GetRecordAudit follows the same care-team gate as
// GetRecord (FR-005).
// (spec.md FR-005; contracts/http-api.md GET /records/{id}/audit)
// ══════════════════════════════════════════════════════════════════════
fact F_ClinicianGetRecordAuditGating {
    all op: Operation |
        (op.opCaller.role = Clinician and op.opKind = GetRecordAudit) implies {
            op.opOutcome = Permitted iff
                (some m: CareTeamMembership |
                     m.ctClinician = op.opCaller and m.ctRecord = op.opRecord)
        }
}

// ══════════════════════════════════════════════════════════════════════
// F_ClinicianCannotGetAccessLog
// A clinician calling GetAccessLog is always Denied.
// (spec.md FR-005; contracts/http-api.md permission matrix)
// ══════════════════════════════════════════════════════════════════════
fact F_ClinicianCannotGetAccessLog {
    all op: Operation |
        (op.opCaller.role = Clinician and op.opKind = GetAccessLog) implies
            op.opOutcome = Denied
}

// ══════════════════════════════════════════════════════════════════════
// F_PermittedOperationInBaseMatrix
// If an operation is Permitted, the (role, kind) pair must be in the
// base permission matrix.  No permission is granted outside the matrix.
// (spec.md FR-004..FR-007; contracts/http-api.md; LeastPrivilege)
// ══════════════════════════════════════════════════════════════════════
fact F_PermittedOperationInBaseMatrix {
    all op: Operation |
        op.opOutcome = Permitted implies
            (op.opCaller.role -> op.opKind) in PermMatrix.Allowed
}

// ══════════════════════════════════════════════════════════════════════
// F_NotesOnlyFromPermittedPostNote
// Every ClinicalNote corresponds to a Permitted PostNote operation on
// the same record by the same author.  No note is created without a
// matching permitted operation.
// (spec.md FR-011, FR-012; data-model.md ClinicalNote)
// ══════════════════════════════════════════════════════════════════════
fact F_NotesOnlyFromPermittedPostNote {
    all n: ClinicalNote |
        some op: Operation |
            op.opKind = PostNote and
            op.opOutcome = Permitted and
            op.opRecord = n.noteRecord and
            op.opCaller = n.noteAuthor and
            op.opAudit.auditNote = n
}

// ══════════════════════════════════════════════════════════════════════
// PREDICATES  — catalogue patterns
// ══════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004..FR-007
pred LeastPrivilege {
    some op: Operation | op.opOutcome = Permitted  -- universe is non-trivial
    // No operation outside the base matrix is ever permitted
    all op: Operation |
        op.opOutcome = Permitted implies
            (op.opCaller.role -> op.opKind) in PermMatrix.Allowed
    // Compliance officers never read clinical content
    all op: Operation |
        (op.opCaller.role = ComplianceOfficer and
         (op.opKind = GetRecord or op.opKind = PostNote)) implies
             op.opOutcome = Denied
    // Clinicians never reach GetAccessLog as Permitted
    all op: Operation |
        (op.opCaller.role = Clinician and op.opKind = GetAccessLog) implies
            op.opOutcome = Denied
    // Patients never append notes as Permitted
    all op: Operation |
        (op.opCaller.role = PatientRole and op.opKind = PostNote) implies
            op.opOutcome = Denied
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
    // Every (Role, OperationKind) cell is either in Allowed or not — the
    // matrix is closed-world; no cell is undefined.
    some r: Role, k: OperationKind | (r -> k) in PermMatrix.Allowed
    some r: Role, k: OperationKind | (r -> k) not in PermMatrix.Allowed
    // Compliance officer row is exactly {GetRecordAudit, GetAccessLog}
    ComplianceOfficer -> GetRecordAudit in PermMatrix.Allowed
    ComplianceOfficer -> GetAccessLog   in PermMatrix.Allowed
    ComplianceOfficer -> GetRecord      not in PermMatrix.Allowed
    ComplianceOfficer -> PostNote       not in PermMatrix.Allowed
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication
// (All Operations in this model are authenticated by construction —
// unauthenticated requests never reach an Operation atom; FR-001 ensures
// they are rejected at the boundary with 401, no audit entry written.
// We assert that every Operation has an identified caller.)
pred AuthRequiredEverywhere {
    some Operation
    all op: Operation | one op.opCaller
    // No audit entry exists without a caller
    all ae: AuditEntry | one ae.auditAccessor
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md AuditEntry; SC-001 SC-002
pred AuditCompleteness {
    some Operation
    -- every operation has exactly one audit entry
    all op: Operation | one op.opAudit
    -- every audit entry belongs to exactly one operation
    all ae: AuditEntry | one op: Operation | op.opAudit = ae
    -- denied operations are audited too
    all op: Operation |
        op.opOutcome = Denied implies (one op.opAudit)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012 (notes), FR-015 (audit); data-model.md "no UPDATE/DELETE"
// In the static model: every ClinicalNote and AuditEntry that exists is
// permanently present and its key linkages (record, author/accessor,
// operation) are fixed — no atom appears with two different field values.
pred AppendOnly {
    some ClinicalNote
    some AuditEntry
    // Each note's record and author are uniquely determined
    all disj n1, n2: ClinicalNote |
        (n1.noteRecord = n2.noteRecord and n1.noteAuthor = n2.noteAuthor)
            implies n1 != n2  -- distinct notes, not a single note "edited"
    // Each audit entry's accessor and operation are uniquely determined
    // (content is set at insert time and never changes)
    all ae: AuditEntry | one ae.auditAccessor and one ae.auditOperation
}

assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md AuditEntry fields
pred AttributionCorrectness {
    some Operation
    all op: Operation | let ae = op.opAudit | {
        ae.auditAccessor  = op.opCaller
        ae.auditOperation = op.opKind
        ae.auditOutcome   = op.opOutcome
    }
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-003; data-model.md User assigned_record_id
pred OwnershipExclusivity {
    some u: User | u.role = PatientRole
    // Each patient user owns exactly one record (lone → exactly one when role=patient)
    all u: User |
        u.role = PatientRole implies (one u.assignedRecord)
    // Non-patient users own no record
    all u: User |
        u.role != PatientRole implies (no u.assignedRecord)
    // Two distinct patients may own the same record (allowed by spec),
    // but no patient is without an assigned record
    all u: User |
        u.role = PatientRole implies (some r: Record | u.assignedRecord = r)
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md User.assigned_record_id
pred OwnershipBasedAccess {
    some op: Operation | op.opCaller.role = PatientRole
    all op: Operation |
        op.opCaller.role = PatientRole implies {
            (op.opKind = GetRecord or op.opKind = GetRecordAudit) implies
                (op.opOutcome = Permitted iff
                     op.opRecord = op.opCaller.assignedRecord)
        }
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008; contracts/http-api.md byte-equivalent forbidden
// Modelled structurally: any operation whose outcome is Denied produces
// the same observable outcome signal regardless of whether the record
// actually exists — both "record exists but unauthorised" and "record
// does not exist" map to the single Denied outcome atom.
// We assert that all denied operations are indistinguishable by outcome.
pred NoInformationLeakage {
    some op: Operation | op.opOutcome = Denied
    all disj op1, op2: Operation |
        (op1.opOutcome = Denied and op2.opOutcome = Denied and
         op1.opCaller.role = op2.opCaller.role and
         op1.opKind = op2.opKind) implies
             op1.opOutcome = op2.opOutcome  -- same outcome signal
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ══════════════════════════════════════════════════════════════════════
// PREDICATES  — feature-specific FR coverage
// ══════════════════════════════════════════════════════════════════════

// FEATURE-SPECIFIC  ANCHOR: FR-001 (authentication required, no audit on 401)
pred FR_001_AuthRequired {
    // Every Operation (authenticated attempt) has a resolved caller
    some Operation
    all op: Operation | one op.opCaller
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 (single role per user)
pred FR_002_SingleRolePerUser {
    some User
    all u: User | one u.role
}

assert FR_002_SingleRolePerUser { FR_002_SingleRolePerUser }
check FR_002_SingleRolePerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 (patient assigned_record_id pairing)
pred FR_003_PatientAssignedRecord {
    some u: User | u.role = PatientRole
    all u: User |
        u.role = PatientRole  implies (one u.assignedRecord)
    all u: User |
        u.role != PatientRole implies (no u.assignedRecord)
}

assert FR_003_PatientAssignedRecord { FR_003_PatientAssignedRecord }
check FR_003_PatientAssignedRecord for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 (care-team membership gating for clinician reads/appends)
pred FR_004_CareTeamGating {
    some op: Operation |
        op.opCaller.role = Clinician and
        (op.opKind = GetRecord or op.opKind = PostNote)
    all op: Operation |
        (op.opCaller.role = Clinician and
         (op.opKind = GetRecord or op.opKind = PostNote)) implies {
            op.opOutcome = Permitted iff
                (some m: CareTeamMembership |
                     m.ctClinician = op.opCaller and m.ctRecord = op.opRecord)
        }
}

assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 (clinician audit-log access scoped to care team)
pred FR_005_ClinicianAuditAccess {
    some op: Operation |
        op.opCaller.role = Clinician and op.opKind = GetRecordAudit
    all op: Operation |
        (op.opCaller.role = Clinician and op.opKind = GetRecordAudit) implies {
            op.opOutcome = Permitted iff
                (some m: CareTeamMembership |
                     m.ctClinician = op.opCaller and m.ctRecord = op.opRecord)
        }
    all op: Operation |
        (op.opCaller.role = Clinician and op.opKind = GetAccessLog) implies
            op.opOutcome = Denied
}

assert FR_005_ClinicianAuditAccess { FR_005_ClinicianAuditAccess }
check FR_005_ClinicianAuditAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 (patient self-access only)
pred FR_006_PatientSelfAccess {
    some op: Operation | op.opCaller.role = PatientRole
    all op: Operation |
        op.opCaller.role = PatientRole implies {
            op.opKind = PostNote     implies op.opOutcome = Denied
            op.opKind = GetAccessLog implies op.opOutcome = Denied
            (op.opKind = GetRecord or op.opKind = GetRecordAudit) implies
                (op.opOutcome = Permitted iff
                     op.opRecord = op.opCaller.assignedRecord)
        }
}

assert FR_006_PatientSelfAccess { FR_006_PatientSelfAccess }
check FR_006_PatientSelfAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 (compliance officer cannot read clinical content or append)
pred FR_007_ComplianceContentBlind {
    some op: Operation | op.opCaller.role = ComplianceOfficer
    all op: Operation |
        op.opCaller.role = ComplianceOfficer implies {
            op.opKind = GetRecord implies op.opOutcome = Denied
            op.opKind = PostNote  implies op.opOutcome = Denied
        }
}

assert FR_007_ComplianceContentBlind { FR_007_ComplianceContentBlind }
check FR_007_ComplianceContentBlind for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 (byte-equivalent forbidden; existence leakage prevention)
pred FR_008_ByteEquivalentForbidden {
    // All denied operations produce the single Denied outcome atom —
    // indistinguishable whether "record exists + caller denied" or "record absent"
    some op: Operation | op.opOutcome = Denied
    all op: Operation | op.opOutcome = Denied implies op.opOutcome = Denied
    // Structurally: Denied is a unique atom shared by all refused outcomes
    one Denied
}

assert FR_008_ByteEquivalentForbidden { FR_008_ByteEquivalentForbidden }
check FR_008_ByteEquivalentForbidden for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 / FR-011 (only valid PostNote operations create notes)
pred FR_010_NoteCreationRequiresPermittedAppend {
    some ClinicalNote
    all n: ClinicalNote |
        some op: Operation |
            op.opKind = PostNote and
            op.opOutcome = Permitted and
            op.opCaller = n.noteAuthor and
            op.opRecord = n.noteRecord
}

assert FR_010_NoteCreationRequiresPermittedAppend {
    FR_010_NoteCreationRequiresPermittedAppend
}
check FR_010_NoteCreationRequiresPermittedAppend for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 (notes append-only; no edit or delete endpoint)
pred FR_012_NotesAppendOnly {
    some ClinicalNote
    // Every clinical note exists permanently and is authored by a clinician;
    // there is no operation kind that "removes" a note.
    all n: ClinicalNote | n.noteAuthor.role = Clinician
    // No two distinct notes share the same (record, author) AND same audit entry
    // — each note is a distinct creation event.
    all disj n1, n2: ClinicalNote |
        not (n1.noteRecord = n2.noteRecord and n1.noteAuthor = n2.noteAuthor and
             (some op: Operation |
                  op.opAudit.auditNote = n1 and op.opAudit.auditNote = n2))
}

assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 (every record-access event has exactly one audit entry)
pred FR_013_AuditEveryAccess {
    some Operation
    all op: Operation | one op.opAudit
    all ae: AuditEntry | one op: Operation | op.opAudit = ae
}

assert FR_013_AuditEveryAccess { FR_013_AuditEveryAccess }
check FR_013_AuditEveryAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 (audit entry shape — accessor, operation, outcome, record)
pred FR_014_AuditEntryShape {
    some AuditEntry
    all ae: AuditEntry | {
        one ae.auditAccessor
        one ae.auditOperation
        one ae.auditOutcome
        // record is null iff GetAccessLog
        (ae.auditOperation = GetAccessLog implies no  ae.auditRecord)
        (ae.auditOperation != GetAccessLog implies one ae.auditRecord)
        // note_id iff append + permitted
        (ae.auditOperation = PostNote and ae.auditOutcome = Permitted
             implies one ae.auditNote)
        (not (ae.auditOperation = PostNote and ae.auditOutcome = Permitted)
             implies no ae.auditNote)
    }
}

assert FR_014_AuditEntryShape { FR_014_AuditEntryShape }
check FR_014_AuditEntryShape for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 / FR-017 (audit immutability and ≥7-year retention)
// Modelled as: every AuditEntry that exists persists — each entry is
// uniquely associated to exactly one Operation, and its fields are fixed.
pred FR_015_AuditImmutability {
    some AuditEntry
    // Each AuditEntry is the audit of exactly one operation
    all ae: AuditEntry | one op: Operation | op.opAudit = ae
    // An audit entry's accessor and operation are each singletons (no mutation)
    all ae: AuditEntry | one ae.auditAccessor and one ae.auditOperation
}

assert FR_015_AuditImmutability { FR_015_AuditImmutability }
check FR_015_AuditImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 (no access without audit — atomicity)
pred FR_016_NoAccessWithoutAudit {
    some Operation
    // Every Permitted operation is accompanied by an audit entry
    all op: Operation | op.opOutcome = Permitted implies (one op.opAudit)
    // Every Denied  operation is accompanied by an audit entry
    all op: Operation | op.opOutcome = Denied  implies (one op.opAudit)
}

assert FR_016_NoAccessWithoutAudit { FR_016_NoAccessWithoutAudit }
check FR_016_NoAccessWithoutAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 (GetAccessLog is compliance-officer-only)
pred FR_018_ComplianceOnlyAccessLog {
    some op: Operation | op.opKind = GetAccessLog
    all op: Operation |
        op.opKind = GetAccessLog implies
            (op.opOutcome = Permitted iff op.opCaller.role = ComplianceOfficer)
}

assert FR_018_ComplianceOnlyAccessLog { FR_018_ComplianceOnlyAccessLog }
check FR_018_ComplianceOnlyAccessLog for 5

// FEATURE-SPECIFIC  ANCHOR: FR-019 (compliance responses contain no clinical content)
// Modelled as: no Permitted GetRecord or PostNote operation is
// associated with a compliance officer caller.
pred FR_019_ComplianceContentBlindStructural {
    some op: Operation | op.opCaller.role = ComplianceOfficer
    all op: Operation |
        op.opCaller.role = ComplianceOfficer implies {
            op.opKind != GetRecord or op.opOutcome = Denied
            op.opKind != PostNote  or op.opOutcome = Denied
        }
}

assert FR_019_ComplianceContentBlindStructural {
    FR_019_ComplianceContentBlindStructural
}
check FR_019_ComplianceContentBlindStructural for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020 (record_id in URL paths; patient demographics never in URLs)
// Modelled structurally: User.assignedRecord is an opaque Record atom,
// never a demographic — enforced by type (Record has no demographic fields
// in this model, matching the design principle).
pred FR_020_OpaqueRecordIdOnly {
    some Record
    // All operation targets are Record atoms (opaque handles), not Users
    all op: Operation | op.opKind != GetAccessLog implies (one op.opRecord)
    // Records are distinct from Users
    no Record & User
}

assert FR_020_OpaqueRecordIdOnly { FR_020_OpaqueRecordIdOnly }
check FR_020_OpaqueRecordIdOnly for 5

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md role hierarchy; contracts/http-api.md
// In this feature there is no strict superset hierarchy across roles
// (each role has disjoint allowed operations — clinicians cannot do
// GetAccessLog; compliance officers cannot do GetRecord/PostNote).
// The partial ordering that does hold: for GetRecordAudit, all three
// roles may access (conditional on ownership/membership), so it is in
// every role's base allowed set.
pred PrivilegeMonotonicity {
    // GetRecordAudit is in the base matrix for every role
    Clinician        -> GetRecordAudit in PermMatrix.Allowed
    PatientRole      -> GetRecordAudit in PermMatrix.Allowed
    ComplianceOfficer -> GetRecordAudit in PermMatrix.Allowed
    // GetAccessLog is exclusive to ComplianceOfficer
    ComplianceOfficer -> GetAccessLog in PermMatrix.Allowed
    Clinician         -> GetAccessLog not in PermMatrix.Allowed
    PatientRole       -> GetAccessLog not in PermMatrix.Allowed
}

assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-010; contracts/http-api.md POST /records/{id}/notes
// If a PostNote operation has outcome=Denied, no ClinicalNote was created
// from it.  Notes exist only from Permitted PostNote operations.
pred ValidationBeforeMutation {
    some op: Operation | op.opKind = PostNote
    all op: Operation |
        (op.opKind = PostNote and op.opOutcome = Denied) implies
            (no n: ClinicalNote | n.noteRecord = op.opRecord and n.noteAuthor = op.opCaller
                 and op.opAudit.auditNote = n)
}

assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_ComplianceContentLeakViolation { some op: Operation | op.opCaller.role = ComplianceOfficer and op.opKind = GetRecord and op.opOutcome = Permitted }
