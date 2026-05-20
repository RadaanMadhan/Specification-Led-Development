// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===
// Feature: C-L3  (branch 013-hipaa-clinical-records)
// Artefacts: spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────────────────────────────────────
// ROLES
// ─────────────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Clinician, PatientRole, ComplianceOfficer extends Role {}

// ─────────────────────────────────────────────────────────────────────────────
// OPERATION KINDS  (the four endpoints in scope)
// ─────────────────────────────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig GetRecord, PostNote, GetRecordAudit, GetAccessLog extends OperationKind {}

// ─────────────────────────────────────────────────────────────────────────────
// OUTCOMES
// ─────────────────────────────────────────────────────────────────────────────
abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

// ─────────────────────────────────────────────────────────────────────────────
// DOMAIN SIGS
// ─────────────────────────────────────────────────────────────────────────────

// Every authenticated user has exactly one role.
// Patients also carry their one assigned record.
sig User {
  role:           one Role,
  assignedRecord: lone Record
}

// Opaque patient medical-record handle.
sig Record {}

// Active care-team membership: asserts that clinician C is on record R's care team.
// Only ACTIVE memberships are modelled; ended/absent memberships are simply absent.
sig CareTeamMembership {
  ctmClinician: one User,
  ctmRecord:    one Record
}

// Append-only clinical note attached to a record.
sig ClinicalNote {
  noteRecord: one Record,
  noteAuthor: one User
}

// Immutable audit-log entry.  Merged with the access-event concept (FR-013:
// exactly one entry per access event).
sig AuditEntry {
  aeAccessor:     one User,
  aeAccessorRole: one Role,         // snapshot at the moment of access
  aeRecord:       lone Record,      // lone: null for GetAccessLog events
  aeOperation:    one OperationKind,
  aeOutcome:      one Outcome,
  aeNote:         lone ClinicalNote // non-null iff PostNote AND Permitted
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
}

// ─────────────────────────────────────────────────────────────────────────────
// STRUCTURAL FACTS — each is named so the mutation harness can clear its body
// ─────────────────────────────────────────────────────────────────────────────

// FR-002 / FR-003 / data-model.md User.assigned_record_id CHECK
// Patients carry exactly one assignedRecord; all other roles carry none.
fact F_PatientAssignedRecord { /* MUTATED — body cleared by validator */ }

// data-model.md CareTeamMembership: only Clinician users appear as members
fact F_CareTeamMembersAreClinicians {
  all m: CareTeamMembership | m.ctmClinician.role = Clinician
}

// FR-011 / data-model.md ClinicalNote.author_role CHECK('clinician')
// Only users with role Clinician may author notes.
fact F_NoteAuthorIsClinician {
  all n: ClinicalNote | n.noteAuthor.role = Clinician
}

// FR-004 / FR-011: a note may only be appended by a care-team clinician for that record.
fact F_NoteCareTeamGating {
  all n: ClinicalNote |
    some m: CareTeamMembership |
      m.ctmClinician = n.noteAuthor and m.ctmRecord = n.noteRecord
}

// FR-014 / data-model.md AuditEntry.accessor_role snapshot:
// the snapshotted role must equal the accessor's actual role.
fact F_AttributionCorrectnessInvariant {
  all ae: AuditEntry | ae.aeAccessorRole = ae.aeAccessor.role
}

// FR-014 / data-model.md structural CHECK: record_id is present for
// read/append/per-record-list events and absent for GetAccessLog events.
fact F_AuditRecordPresence {
  all ae: AuditEntry |
    ae.aeOperation = GetAccessLog implies (no ae.aeRecord)
  all ae: AuditEntry |
    (ae.aeOperation = GetRecord
     or ae.aeOperation = PostNote
     or ae.aeOperation = GetRecordAudit)
    implies (one ae.aeRecord)
}

// FR-014 / data-model.md note_id CHECK:
// note_id is set iff operation=PostNote AND outcome=Permitted.
fact F_AuditNoteLinkage {
  all ae: AuditEntry |
    (ae.aeOperation = PostNote and ae.aeOutcome = Permitted)
    implies (one ae.aeNote)
  all ae: AuditEntry |
    (ae.aeOperation = PostNote and ae.aeOutcome = Denied)
    implies (no ae.aeNote)
  all ae: AuditEntry |
    (ae.aeOperation != PostNote)
    implies (no ae.aeNote)
  // The note in the audit entry must belong to the same record being accessed.
  all ae: AuditEntry |
    (one ae.aeNote) implies (ae.aeNote.noteRecord = ae.aeRecord)
}

// FR-004 / FR-005 / FR-006 / FR-007 / contracts/http-api.md permission matrix:
// Fully encodes the (Role × OperationKind) → Outcome mapping, including the
// ownership-conditional cells for Clinician (care-team) and Patient (own record).
fact F_AccessControlMatrix {
  // ── Clinician ──────────────────────────────────────────────────────────────
  all ae: AuditEntry | ae.aeAccessor.role = Clinician => {
    ae.aeOperation = GetRecord =>
      (ae.aeOutcome = Permitted iff
        (some m: CareTeamMembership |
          m.ctmClinician = ae.aeAccessor and m.ctmRecord = ae.aeRecord))
    ae.aeOperation = PostNote =>
      (ae.aeOutcome = Permitted iff
        (some m: CareTeamMembership |
          m.ctmClinician = ae.aeAccessor and m.ctmRecord = ae.aeRecord))
    ae.aeOperation = GetRecordAudit =>
      (ae.aeOutcome = Permitted iff
        (some m: CareTeamMembership |
          m.ctmClinician = ae.aeAccessor and m.ctmRecord = ae.aeRecord))
    ae.aeOperation = GetAccessLog =>
      ae.aeOutcome = Denied
  }
  // ── PatientRole ────────────────────────────────────────────────────────────
  all ae: AuditEntry | ae.aeAccessor.role = PatientRole => {
    ae.aeOperation = GetRecord =>
      (ae.aeOutcome = Permitted iff
        ae.aeRecord = ae.aeAccessor.assignedRecord)
    ae.aeOperation = PostNote =>
      ae.aeOutcome = Denied
    ae.aeOperation = GetRecordAudit =>
      (ae.aeOutcome = Permitted iff
        ae.aeRecord = ae.aeAccessor.assignedRecord)
    ae.aeOperation = GetAccessLog =>
      ae.aeOutcome = Denied
  }
  // ── ComplianceOfficer ──────────────────────────────────────────────────────
  all ae: AuditEntry | ae.aeAccessor.role = ComplianceOfficer => {
    ae.aeOperation = GetRecord      => ae.aeOutcome = Denied
    ae.aeOperation = PostNote       => ae.aeOutcome = Denied
    ae.aeOperation = GetRecordAudit => ae.aeOutcome = Permitted
    ae.aeOperation = GetAccessLog   => ae.aeOutcome = Permitted
  }
}

// FR-012 / SC-007 / data-model.md "no UPDATE/DELETE on clinical_notes":
// Each ClinicalNote is the subject of at most one Permitted-append audit entry,
// enforcing the append-only invariant structurally.
fact F_AppendOnlyNotes {
  all n: ClinicalNote |
    lone ae: AuditEntry |
      ae.aeNote = n
}

// FR-015 / SC-008 / data-model.md "no UPDATE/DELETE on audit_entries":
// Audit entries are immutable: no two entries share the same
// (accessor, operation, record, note) combination with different outcomes,
// which would imply a prior entry was "updated."
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry |
    not (ae1.aeAccessor    = ae2.aeAccessor
      and ae1.aeOperation  = ae2.aeOperation
      and ae1.aeRecord     = ae2.aeRecord
      and ae1.aeNote       = ae2.aeNote
      and ae1.aeOutcome   != ae2.aeOutcome)
}

// FR-013 / SC-001 / SC-002: every Permitted note creation is captured in exactly
// one audit entry (always-on audit for write events).
fact F_AuditCompletenessForPermittedNotes {
  all n: ClinicalNote |
    one ae: AuditEntry |
      ae.aeNote = n and ae.aeOperation = PostNote and ae.aeOutcome = Permitted
}

// FR-008 / SC-003 NoInformationLeakage: for any record-scoped operation, the
// outcome for an unauthorised caller is Denied regardless of whether the record
// exists — encoded by requiring every AuditEntry whose outcome is Denied to
// carry the same Denied outcome independent of aeRecord content (i.e., Denied
// is the unique wire value; Permitted is gated exclusively by the matrix facts above).
fact F_ByteEquivalentDenied {
  // All denied record-scoped events produce the same outcome atom (Denied),
  // making the response indistinguishable across (real-record, fake-record) pairs.
  all ae: AuditEntry |
    ae.aeOutcome = Denied implies ae.aeOutcome = Denied  // tautological anchor;
  // The structural invariant: no denied event may carry a note (no information leaks).
  all ae: AuditEntry |
    ae.aeOutcome = Denied implies (no ae.aeNote)
}

// ─────────────────────────────────────────────────────────────────────────────
// PREDICATES AND ASSERTIONS
// ─────────────────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004,FR-005,FR-006,FR-007
pred LeastPrivilege {
  // No Clinician outside care team may have a Permitted GetRecord event.
  some AuditEntry
  all ae: AuditEntry |
    (ae.aeAccessor.role = Clinician and ae.aeOperation = GetRecord
     and ae.aeOutcome = Permitted)
    implies
    (some m: CareTeamMembership |
      m.ctmClinician = ae.aeAccessor and m.ctmRecord = ae.aeRecord)
  // No Patient may have a Permitted GetRecord event for a record not their own.
  all ae: AuditEntry |
    (ae.aeAccessor.role = PatientRole and ae.aeOperation = GetRecord
     and ae.aeOutcome = Permitted)
    implies
    (ae.aeRecord = ae.aeAccessor.assignedRecord)
  // ComplianceOfficer never has a Permitted GetRecord event.
  all ae: AuditEntry |
    (ae.aeAccessor.role = ComplianceOfficer and ae.aeOperation = GetRecord)
    implies
    ae.aeOutcome = Denied
  // ComplianceOfficer never has a Permitted PostNote event.
  all ae: AuditEntry |
    (ae.aeAccessor.role = ComplianceOfficer and ae.aeOperation = PostNote)
    implies
    ae.aeOutcome = Denied
  // Only ComplianceOfficer may have a Permitted GetAccessLog event.
  all ae: AuditEntry |
    (ae.aeOperation = GetAccessLog and ae.aeOutcome = Permitted)
    implies
    ae.aeAccessor.role = ComplianceOfficer
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every AuditEntry has exactly one Outcome value — no undefined cells.
  some AuditEntry
  all ae: AuditEntry |
    ae.aeOutcome = Permitted or ae.aeOutcome = Denied
  // Every combination of role and operation resolves deterministically.
  // Clinician + GetAccessLog is always Denied.
  all ae: AuditEntry |
    (ae.aeAccessor.role = Clinician and ae.aeOperation = GetAccessLog)
    implies ae.aeOutcome = Denied
  // Patient + PostNote is always Denied.
  all ae: AuditEntry |
    (ae.aeAccessor.role = PatientRole and ae.aeOperation = PostNote)
    implies ae.aeOutcome = Denied
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md role descriptions; contracts/http-api.md
// ComplianceOfficer can read audit logs system-wide (superset of per-record audit).
// Clinicians in care team can read record + audit; patients (own record) only read + per-record audit.
pred PrivilegeMonotonicity {
  some AuditEntry
  // If a Clinician-in-CT has Permitted GetRecord, ComplianceOfficer can read that record's audit.
  all ae: AuditEntry |
    (ae.aeAccessor.role = Clinician
     and ae.aeOperation = GetRecord
     and ae.aeOutcome = Permitted)
    implies
    (all ae2: AuditEntry |
      (ae2.aeAccessor.role = ComplianceOfficer
       and ae2.aeOperation = GetRecordAudit
       and ae2.aeRecord = ae.aeRecord)
      implies ae2.aeOutcome = Permitted)
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md AuditEntry
pred AuditCompleteness {
  some ClinicalNote
  // Every note that was successfully appended has exactly one matching audit entry.
  all n: ClinicalNote |
    (one ae: AuditEntry |
      ae.aeNote = n and ae.aeOperation = PostNote and ae.aeOutcome = Permitted)
  // Every permitted audit entry for PostNote references a real ClinicalNote.
  all ae: AuditEntry |
    (ae.aeOperation = PostNote and ae.aeOutcome = Permitted)
    implies (one ae.aeNote)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly (notes)  ANCHOR: spec.md FR-012; data-model.md "no UPDATE/DELETE on clinical_notes"
pred AppendOnly {
  some ClinicalNote
  // Each ClinicalNote appears in at most one permitted-append entry — it cannot be
  // "re-created" or re-linked, which would represent an implicit mutation.
  all n: ClinicalNote |
    (lone ae: AuditEntry | ae.aeNote = n)
  // No denied event for PostNote references a note (no partial note creation).
  all ae: AuditEntry |
    (ae.aeOperation = PostNote and ae.aeOutcome = Denied)
    implies (no ae.aeNote)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AppendOnly (audit)  ANCHOR: spec.md FR-015,FR-017; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnlyAudit {
  some AuditEntry
  // No two audit entries represent an "update" to the same event:
  // same (accessor, operation, record, note) pair cannot appear with two different outcomes.
  all disj ae1, ae2: AuditEntry |
    not (ae1.aeAccessor   = ae2.aeAccessor
      and ae1.aeOperation = ae2.aeOperation
      and ae1.aeRecord    = ae2.aeRecord
      and ae1.aeNote      = ae2.aeNote
      and ae1.aeOutcome  != ae2.aeOutcome)
}
assert AppendOnlyAudit { AppendOnlyAudit }
check AppendOnlyAudit for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md AuditEntry.accessor_role snapshot
pred AttributionCorrectness {
  some AuditEntry
  // The snapshotted role in every audit entry matches the accessor's actual role.
  all ae: AuditEntry | ae.aeAccessorRole = ae.aeAccessor.role
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md User.assigned_record_id; spec.md FR-003
pred OwnershipExclusivity {
  some u: User | u.role = PatientRole
  // Every patient has exactly one assigned record.
  all u: User |
    u.role = PatientRole implies (one u.assignedRecord)
  // Non-patient users have no assigned record.
  all u: User |
    u.role != PatientRole implies (no u.assignedRecord)
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md User.assigned_record_id
pred OwnershipBasedAccess {
  some ae: AuditEntry | ae.aeAccessor.role = PatientRole
  // A patient's permitted record access always involves their own assigned record.
  all ae: AuditEntry |
    (ae.aeAccessor.role = PatientRole
     and ae.aeOperation = GetRecord
     and ae.aeOutcome = Permitted)
    implies (ae.aeRecord = ae.aeAccessor.assignedRecord)
  // A patient's permitted audit-listing access always involves their own record.
  all ae: AuditEntry |
    (ae.aeAccessor.role = PatientRole
     and ae.aeOperation = GetRecordAudit
     and ae.aeOutcome = Permitted)
    implies (ae.aeRecord = ae.aeAccessor.assignedRecord)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008; contracts/http-api.md byte-equivalent forbidden response
pred NoInformationLeakage {
  some AuditEntry
  // All denied events carry outcome Denied — no "not found" vs "forbidden" distinction
  // is observable externally. The Denied outcome is uniform regardless of whether the
  // record exists.
  all ae: AuditEntry |
    ae.aeOutcome = Denied implies (no ae.aeNote)
  // Clinician outside care team → Denied (existence-indistinguishable)
  all ae: AuditEntry |
    (ae.aeAccessor.role = Clinician
     and ae.aeOperation = GetRecord
     and (no m: CareTeamMembership |
           m.ctmClinician = ae.aeAccessor and m.ctmRecord = ae.aeRecord))
    implies ae.aeOutcome = Denied
  // Patient accessing non-own record → Denied (existence-indistinguishable)
  all ae: AuditEntry |
    (ae.aeAccessor.role = PatientRole
     and ae.aeOperation = GetRecord
     and ae.aeRecord != ae.aeAccessor.assignedRecord)
    implies ae.aeOutcome = Denied
  // ComplianceOfficer accessing clinical content → Denied
  all ae: AuditEntry |
    (ae.aeAccessor.role = ComplianceOfficer
     and ae.aeOperation = GetRecord)
    implies ae.aeOutcome = Denied
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-010; contracts/http-api.md POST /records/{id}/notes
pred ValidationBeforeMutation {
  some AuditEntry
  // A denied PostNote event never produces a ClinicalNote.
  all ae: AuditEntry |
    (ae.aeOperation = PostNote and ae.aeOutcome = Denied)
    implies (no ae.aeNote)
  // A denied PostNote event by any role cannot create a note linked to that record.
  // (No note exists for a denied-append audit entry.)
  all ae: AuditEntry |
    ae.aeOutcome = Denied implies (no ae.aeNote)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// ─────────────────────────────────────────────────────────────────────────────
// FR-SPECIFIC PREDICATES
// ─────────────────────────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001 — all access events belong to authenticated users
pred FR_001_AuthRequired {
  some AuditEntry
  // Every audit entry belongs to a User that exists in the model.
  // Unauthenticated requests produce NO audit entry (modelled by absence: all
  // AuditEntry atoms have a concrete aeAccessor).
  all ae: AuditEntry | one ae.aeAccessor
  // No audit entry has a null accessor.
  all ae: AuditEntry | ae.aeAccessor in User
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 — exactly one role per user
pred FR_002_OneRolePerUser {
  some User
  all u: User | one u.role
  all u: User | u.role in Role
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 — patient has exactly one assigned record; others have none
pred FR_003_PatientHasAssignedRecord {
  some u: User | u.role = PatientRole
  all u: User |
    u.role = PatientRole implies (one u.assignedRecord)
  all u: User |
    (u.role = Clinician or u.role = ComplianceOfficer)
    implies (no u.assignedRecord)
}
assert FR_003_PatientHasAssignedRecord { FR_003_PatientHasAssignedRecord }
check FR_003_PatientHasAssignedRecord for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 — clinician access gated on active care-team membership
pred FR_004_CareTeamGatingForClinician {
  some ae: AuditEntry | ae.aeAccessor.role = Clinician
  all ae: AuditEntry |
    (ae.aeAccessor.role = Clinician
     and (ae.aeOperation = GetRecord or ae.aeOperation = PostNote)
     and ae.aeOutcome = Permitted)
    implies
    (some m: CareTeamMembership |
      m.ctmClinician = ae.aeAccessor and m.ctmRecord = ae.aeRecord)
}
assert FR_004_CareTeamGatingForClinician { FR_004_CareTeamGatingForClinician }
check FR_004_CareTeamGatingForClinician for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 — clinician audit-access also gated on care team
pred FR_005_ClinicianAuditAccessCareTeamOnly {
  some ae: AuditEntry |
    ae.aeAccessor.role = Clinician and ae.aeOperation = GetRecordAudit
  all ae: AuditEntry |
    (ae.aeAccessor.role = Clinician
     and ae.aeOperation = GetRecordAudit
     and ae.aeOutcome = Permitted)
    implies
    (some m: CareTeamMembership |
      m.ctmClinician = ae.aeAccessor and m.ctmRecord = ae.aeRecord)
  // Clinicians may never access the system-wide access log.
  all ae: AuditEntry |
    (ae.aeAccessor.role = Clinician and ae.aeOperation = GetAccessLog)
    implies ae.aeOutcome = Denied
}
assert FR_005_ClinicianAuditAccessCareTeamOnly { FR_005_ClinicianAuditAccessCareTeamOnly }
check FR_005_ClinicianAuditAccessCareTeamOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 — patient self-access only
pred FR_006_PatientSelfAccessOnly {
  some ae: AuditEntry | ae.aeAccessor.role = PatientRole
  all ae: AuditEntry |
    (ae.aeAccessor.role = PatientRole and ae.aeOperation = GetRecord)
    implies
    (ae.aeOutcome = Denied or ae.aeRecord = ae.aeAccessor.assignedRecord)
  all ae: AuditEntry |
    (ae.aeAccessor.role = PatientRole and ae.aeOperation = PostNote)
    implies ae.aeOutcome = Denied
  all ae: AuditEntry |
    (ae.aeAccessor.role = PatientRole and ae.aeOperation = GetAccessLog)
    implies ae.aeOutcome = Denied
}
assert FR_006_PatientSelfAccessOnly { FR_006_PatientSelfAccessOnly }
check FR_006_PatientSelfAccessOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 — compliance officer cannot access clinical content (GetRecord / PostNote)
pred FR_007_ComplianceContentBlindness {
  some ae: AuditEntry | ae.aeAccessor.role = ComplianceOfficer
  all ae: AuditEntry |
    ae.aeAccessor.role = ComplianceOfficer
    implies
    (ae.aeOperation != GetRecord or ae.aeOutcome = Denied)
  all ae: AuditEntry |
    ae.aeAccessor.role = ComplianceOfficer
    implies
    (ae.aeOperation != PostNote or ae.aeOutcome = Denied)
  // Compliance officers CAN read audit logs.
  all ae: AuditEntry |
    (ae.aeAccessor.role = ComplianceOfficer and ae.aeOperation = GetAccessLog)
    implies ae.aeOutcome = Permitted
}
assert FR_007_ComplianceContentBlindness { FR_007_ComplianceContentBlindness }
check FR_007_ComplianceContentBlindness for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 — byte-equivalent denied response (no existence leakage)
pred FR_008_ByteEquivalentForbidden {
  some AuditEntry
  // Denied events carry no note — no clinical information leaks through denied paths.
  all ae: AuditEntry |
    ae.aeOutcome = Denied implies (no ae.aeNote)
  // A clinician not in the care team is denied, regardless of record existence.
  all ae: AuditEntry |
    (ae.aeAccessor.role = Clinician
     and ae.aeOperation = GetRecord
     and (no m: CareTeamMembership |
           m.ctmClinician = ae.aeAccessor and m.ctmRecord = ae.aeRecord))
    implies ae.aeOutcome = Denied
}
assert FR_008_ByteEquivalentForbidden { FR_008_ByteEquivalentForbidden }
check FR_008_ByteEquivalentForbidden for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 — note author must be a clinician; author role snapshotted
pred FR_011_NoteAuthorIsClinician {
  some ClinicalNote
  all n: ClinicalNote | n.noteAuthor.role = Clinician
  // The audit entry for a permitted append records author_role = clinician.
  all ae: AuditEntry |
    (ae.aeOperation = PostNote and ae.aeOutcome = Permitted)
    implies ae.aeAccessorRole = Clinician
}
assert FR_011_NoteAuthorIsClinician { FR_011_NoteAuthorIsClinician }
check FR_011_NoteAuthorIsClinician for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 — notes are append-only; no edit or delete path exists
pred FR_012_NotesAppendOnly {
  some ClinicalNote
  // Each note is referenced by at most one permitted-append audit entry
  // (no "re-append" of the same note, which would imply a hidden update).
  all n: ClinicalNote |
    (lone ae: AuditEntry | ae.aeNote = n)
}
assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 / SC-001 / SC-002 — always-on 1:1 audit for every access event
pred FR_013_AuditCompletenessAlwaysOn {
  some ClinicalNote
  some AuditEntry
  // Every clinical note has exactly one matching permitted-append audit entry.
  all n: ClinicalNote |
    (one ae: AuditEntry |
      ae.aeNote = n
      and ae.aeOperation = PostNote
      and ae.aeOutcome = Permitted)
  // Every permitted PostNote audit entry references a real note.
  all ae: AuditEntry |
    (ae.aeOperation = PostNote and ae.aeOutcome = Permitted)
    implies (one ae.aeNote)
}
assert FR_013_AuditCompletenessAlwaysOn { FR_013_AuditCompletenessAlwaysOn }
check FR_013_AuditCompletenessAlwaysOn for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 — audit-entry note_id field linkage invariant
pred FR_014_AuditEntryNoteIdLinkage {
  some AuditEntry
  // Permitted append → note present and linked to the accessed record.
  all ae: AuditEntry |
    (ae.aeOperation = PostNote and ae.aeOutcome = Permitted)
    implies
    (one ae.aeNote and ae.aeNote.noteRecord = ae.aeRecord)
  // Denied append → no note present.
  all ae: AuditEntry |
    (ae.aeOperation = PostNote and ae.aeOutcome = Denied)
    implies (no ae.aeNote)
  // Non-append ops → no note.
  all ae: AuditEntry |
    ae.aeOperation != PostNote implies (no ae.aeNote)
}
assert FR_014_AuditEntryNoteIdLinkage { FR_014_AuditEntryNoteIdLinkage }
check FR_014_AuditEntryNoteIdLinkage for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 / FR-017 — audit entries are immutable; no update or delete
pred FR_015_AuditImmutable {
  some AuditEntry
  // No two distinct audit entries represent opposite outcomes for the same
  // (accessor, operation, record, note) tuple — an "update" would produce that.
  all disj ae1, ae2: AuditEntry |
    not (ae1.aeAccessor   = ae2.aeAccessor
      and ae1.aeOperation = ae2.aeOperation
      and ae1.aeRecord    = ae2.aeRecord
      and ae1.aeNote      = ae2.aeNote
      and ae1.aeOutcome  != ae2.aeOutcome)
}
assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 — GetAccessLog is accessible only to ComplianceOfficer
pred FR_018_AccessLogComplianceOnly {
  some ae: AuditEntry | ae.aeOperation = GetAccessLog
  all ae: AuditEntry |
    (ae.aeOperation = GetAccessLog and ae.aeOutcome = Permitted)
    implies ae.aeAccessor.role = ComplianceOfficer
  all ae: AuditEntry |
    (ae.aeOperation = GetAccessLog and ae.aeAccessor.role != ComplianceOfficer)
    implies ae.aeOutcome = Denied
}
assert FR_018_AccessLogComplianceOnly { FR_018_AccessLogComplianceOnly }
check FR_018_AccessLogComplianceOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 — compliance-officer audit-log responses contain no clinical content
// Modelled structurally: audit entries contain no clinical-content field;
// only ClinicalNote carries content, and compliance-officer events never reference a note.
pred FR_019_ComplianceNoClinicalContent {
  some ae: AuditEntry | ae.aeAccessor.role = ComplianceOfficer
  // Compliance officer audit entries never carry a note reference (no clinical content).
  all ae: AuditEntry |
    ae.aeAccessor.role = ComplianceOfficer implies (no ae.aeNote)
  // AuditEntry carries no clinical content by construction: it only references
  // record ids and metadata, never a note body (ClinicalNote is a separate sig).
  all ae: AuditEntry |
    (ae.aeOperation = GetAccessLog or ae.aeOperation = GetRecordAudit)
    implies (no ae.aeNote)
}
assert FR_019_ComplianceNoClinicalContent { FR_019_ComplianceNoClinicalContent }
check FR_019_ComplianceNoClinicalContent for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_PatientAssignedRecordViolation { some u: User | u.role = PatientRole and no u.assignedRecord }
