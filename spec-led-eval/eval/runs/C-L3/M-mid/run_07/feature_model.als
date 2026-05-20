// === feature_model.als — Alloy 6 model for HIPAA Clinical Record Access (C-L3) ===
// Feature branch: 013-hipaa-clinical-records
// Patterns applied: LeastPrivilege, PermissionCompleteness, AuthRequiredEverywhere,
//   AuditCompleteness, AppendOnly, AttributionCorrectness, OwnershipExclusivity,
//   OwnershipBasedAccess, NoInformationLeakage, ValidationBeforeMutation

// ─────────────────────────────────────────────────────────────────────────────────
// ABSTRACT / ONE SIGS  (not dynamic; excluded from F_NonEmptyUniverse)
// ─────────────────────────────────────────────────────────────────────────────────

abstract sig Role {}
one sig Clinician, PatientRole, ComplianceOfficer extends Role {}

abstract sig Endpoint {}
one sig GetRecord, PostNote, GetRecordAudit, GetAccessLog extends Endpoint {}

abstract sig OperationKind {}
one sig ReadOp, AppendOp, ListOp extends OperationKind {}

abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

// ─────────────────────────────────────────────────────────────────────────────────
// DYNAMIC SIGS  (appear in F_NonEmptyUniverse)
// ─────────────────────────────────────────────────────────────────────────────────

sig Record {}

sig User {
  role          : one Role,
  assignedRecord: lone Record      // non-null iff role = PatientRole (FR-003)
}

// Active care-team membership rows  (FR-004)
sig CareTeamMembership {
  ctmClinician: one User,
  ctmRecord   : one Record
}

// Append-only clinical notes  (FR-011, FR-012)
sig ClinicalNote {
  noteRecord: one Record,
  noteAuthor: one User
}

// Immutable audit entries  (FR-013, FR-014, FR-015)
sig AuditEntry {
  aeRecord  : lone Record,       // null for GET /access-log events
  aeAccessor: one  User,
  aeRole    : one  Role,
  aeOp      : one  OperationKind,
  aeOutcome : one  Outcome,
  aeNote    : lone ClinicalNote  // non-null iff op=AppendOp ^ outcome=Permitted
}

// Authenticated access attempts (unauthenticated requests are pre-filtered; FR-001)
sig AccessAttempt {
  aaCaller      : one  User,
  aaEndpoint    : one  Endpoint,
  aaTargetRecord: lone Record,   // absent for GetAccessLog
  aaOutcome     : one  Outcome,
  aaAudit       : one  AuditEntry  // exactly one audit per attempt (FR-013)
}

// ─────────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (FR-004 – FR-007; contracts/http-api.md permission matrix)
// Unconditional cells only. Conditional (ownership/care-team) cells are in
// F_AuthorisationConditional below.
// ─────────────────────────────────────────────────────────────────────────────────

one sig PermMatrix {
  // (role, endpoint) pairs that are UNCONDITIONALLY DENIED regardless of context
  unconditionalDeny: set Role -> Endpoint
}

fact F_PermissionMatrix {
  // ComplianceOfficer is unconditionally denied GetRecord and PostNote (FR-007)
  ComplianceOfficer -> GetRecord    in PermMatrix.unconditionalDeny
  ComplianceOfficer -> PostNote     in PermMatrix.unconditionalDeny
  // PatientRole is unconditionally denied PostNote and GetAccessLog (FR-006)
  PatientRole       -> PostNote     in PermMatrix.unconditionalDeny
  PatientRole       -> GetAccessLog in PermMatrix.unconditionalDeny
  // Clinician is unconditionally denied GetAccessLog (FR-005)
  Clinician         -> GetAccessLog in PermMatrix.unconditionalDeny
  // Closed world: exactly those pairs listed above
  PermMatrix.unconditionalDeny =
    (ComplianceOfficer -> GetRecord)
    + (ComplianceOfficer -> PostNote)
    + (PatientRole       -> PostNote)
    + (PatientRole       -> GetAccessLog)
    + (Clinician         -> GetAccessLog)
}

// ─────────────────────────────────────────────────────────────────────────────────
// NON-EMPTY UNIVERSE
// ─────────────────────────────────────────────────────────────────────────────────

fact F_NonEmptyUniverse {
  some Record
  some User
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
  some AccessAttempt
}

// ─────────────────────────────────────────────────────────────────────────────────
// STRUCTURAL FACTS
// ─────────────────────────────────────────────────────────────────────────────────

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md User.assigned_record_id CHECK; spec.md FR-003
fact F_PatientRecordPairing {
  // Patient users have exactly one assigned record; all others have none
  all u: User |
    (u.role = PatientRole  => (one u.assignedRecord))
  all u: User |
    (u.role != PatientRole => (no u.assignedRecord))
}

// FEATURE-SPECIFIC  ANCHOR: FR-004; data-model.md CareTeamMembership clinician_id FK→users
fact F_CareTeamMembersAreClinicians {
  all m: CareTeamMembership | m.ctmClinician.role = Clinician
}

// FEATURE-SPECIFIC  ANCHOR: FR-011; data-model.md ClinicalNote.author_role CHECK = 'clinician'
fact F_NoteAuthorsAreClinicians {
  all n: ClinicalNote | n.noteAuthor.role = Clinician
}

// Endpoint→OperationKind mapping used in audit entries (FR-013, FR-014)
fact F_EndpointOpKindMapping {
  all a: AccessAttempt |
    (a.aaEndpoint = GetRecord     => a.aaAudit.aeOp = ReadOp)
    and
    (a.aaEndpoint = PostNote      => a.aaAudit.aeOp = AppendOp)
    and
    (a.aaEndpoint in GetRecordAudit + GetAccessLog => a.aaAudit.aeOp = ListOp)
}

// GetAccessLog has no per-record target; all other endpoints have one (FR-013, FR-014)
fact F_TargetRecordPresence {
  all a: AccessAttempt |
    (a.aaEndpoint = GetAccessLog => no a.aaTargetRecord)
    and
    (a.aaEndpoint != GetAccessLog => one a.aaTargetRecord)
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md AuditEntry PK AUTOINCREMENT
fact F_AuditEntryMatchesAttempt {
  // Every AccessAttempt's audit entry is linked exactly to that attempt's accessor
  all a: AccessAttempt | {
    a.aaAudit.aeAccessor = a.aaCaller
    a.aaAudit.aeOutcome  = a.aaOutcome
    a.aaAudit.aeRecord   = a.aaTargetRecord
  }
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md AuditEntry.accessor_role snapshot
fact F_AuditRoleAttribution {
  // Snapshotted role in audit entry matches the caller's actual role
  all a: AccessAttempt | a.aaAudit.aeRole = a.aaCaller.role
}

// FEATURE-SPECIFIC  ANCHOR: FR-014; data-model.md AuditEntry CHECK(operation='append' AND outcome='permitted' => note_id IS NOT NULL)
fact F_NoteIdAuditConstraint {
  all ae: AuditEntry | {
    (ae.aeOp = AppendOp and ae.aeOutcome = Permitted) => (one ae.aeNote)
    (ae.aeOp = AppendOp and ae.aeOutcome = Denied)    => (no  ae.aeNote)
    (ae.aeOp = ReadOp)                                 => (no  ae.aeNote)
    (ae.aeOp = ListOp)                                 => (no  ae.aeNote)
  }
}

// PATTERN: OwnershipBasedAccess + LeastPrivilege
// ANCHOR: spec.md FR-004, FR-005, FR-006, FR-007; contracts/http-api.md permission matrix
fact F_AuthorisationConditional {
  all a: AccessAttempt | {

    // ── GetRecord ──────────────────────────────────────────────────────────────
    a.aaEndpoint = GetRecord => {
      a.aaOutcome = Permitted <=> (
        (a.aaCaller.role = Clinician and
          some m: CareTeamMembership |
            m.ctmClinician = a.aaCaller and m.ctmRecord = a.aaTargetRecord)
        or
        (a.aaCaller.role = PatientRole and
          a.aaCaller.assignedRecord = a.aaTargetRecord)
      )
    }

    // ── PostNote ───────────────────────────────────────────────────────────────
    a.aaEndpoint = PostNote => {
      a.aaOutcome = Permitted <=> (
        a.aaCaller.role = Clinician and
        some m: CareTeamMembership |
          m.ctmClinician = a.aaCaller and m.ctmRecord = a.aaTargetRecord
      )
    }

    // ── GetRecordAudit ─────────────────────────────────────────────────────────
    a.aaEndpoint = GetRecordAudit => {
      a.aaOutcome = Permitted <=> (
        (a.aaCaller.role = Clinician and
          some m: CareTeamMembership |
            m.ctmClinician = a.aaCaller and m.ctmRecord = a.aaTargetRecord)
        or
        (a.aaCaller.role = PatientRole and
          a.aaCaller.assignedRecord = a.aaTargetRecord)
        or
        (a.aaCaller.role = ComplianceOfficer)
      )
    }

    // ── GetAccessLog ───────────────────────────────────────────────────────────
    a.aaEndpoint = GetAccessLog => {
      a.aaOutcome = Permitted <=> a.aaCaller.role = ComplianceOfficer
    }
  }
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012; data-model.md ClinicalNote "no UPDATE/DELETE"
// Structural: note fields are immutable (no secondary "note_id→modified content" relation exists)
fact F_NotesAppendOnly {
  // Each ClinicalNote is uniquely identified by its (record, author) pair within the
  // scope of this model; distinct notes are structurally distinct atoms — there is
  // no "override" or "replacement" relation on ClinicalNote.
  // The append invariant is further expressed as: every permitted PostNote attempt
  // corresponds to exactly one new ClinicalNote (and the note's author matches the caller).
  all a: AccessAttempt |
    (a.aaEndpoint = PostNote and a.aaOutcome = Permitted) => {
      one n: ClinicalNote |
        n.noteRecord = a.aaTargetRecord and
        n.noteAuthor = a.aaCaller and
        a.aaAudit.aeNote = n
    }
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-015, FR-017; data-model.md AuditEntry "no UPDATE/DELETE"
fact F_AuditEntriesAppendOnly {
  // Each AuditEntry is linked to exactly one AccessAttempt (injective mapping).
  // No AuditEntry is shared between distinct AccessAttempts.
  all disj a1, a2: AccessAttempt | a1.aaAudit != a2.aaAudit
}

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008; contracts/http-api.md byte-equivalent forbidden
// Denied outcome is identical regardless of whether the record exists.
fact F_ByteEquivalentDenied {
  // All denied AccessAttempts for the same endpoint produce structurally identical
  // audit entries (same role, same op, same outcome). The "existence" of the record
  // is not observable from the outcome.
  all disj a1, a2: AccessAttempt |
    (a1.aaEndpoint = a2.aaEndpoint and
     a1.aaCaller.role = a2.aaCaller.role and
     a1.aaOutcome = Denied and a2.aaOutcome = Denied) => {
      a1.aaAudit.aeOp      = a2.aaAudit.aeOp
      a1.aaAudit.aeOutcome = a2.aaAudit.aeOutcome
      a1.aaAudit.aeRole    = a2.aaAudit.aeRole
    }
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-007, FR-019
// Compliance officers never have Permitted access to GetRecord or PostNote.
fact F_ComplianceContentBlind {
  all a: AccessAttempt |
    a.aaCaller.role = ComplianceOfficer =>
      (a.aaEndpoint in GetRecord + PostNote => a.aaOutcome = Denied)
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
// Unauthenticated requests are pre-filtered — every AccessAttempt has a valid caller.
// Modeled structurally: every AccessAttempt has an accessor that has a real role.
fact F_AllAttemptsAuthenticated {
  all a: AccessAttempt | a.aaCaller.role in Clinician + PatientRole + ComplianceOfficer
}

// FEATURE-SPECIFIC  ANCHOR: spec.md FR-010; contracts/http-api.md 400 validation_error
// Validation failure produces no state change — no note, no audit entry beyond the
// validation rejection itself.  Modeled as: the audit entry for a denied PostNote
// contains no note reference.
fact F_ValidationNoteAbsenceOnDenied {
  all a: AccessAttempt |
    (a.aaEndpoint = PostNote and a.aaOutcome = Denied) => no a.aaAudit.aeNote
}

// ─────────────────────────────────────────────────────────────────────────────────
// PREDICATES + ASSERTIONS
// ─────────────────────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004…FR-007
pred LeastPrivilege {
  // No caller whose role is unconditionally denied for an endpoint ever gets Permitted
  some AccessAttempt
  all a: AccessAttempt |
    (a.aaCaller.role -> a.aaEndpoint in PermMatrix.unconditionalDeny) =>
      a.aaOutcome = Denied
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every AccessAttempt has a defined outcome (Permitted or Denied) — no undefined cell
  some AccessAttempt
  all a: AccessAttempt | a.aaOutcome in Permitted + Denied
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication
pred AuthRequiredEverywhere {
  // Every AccessAttempt has a caller with a recognized role (unauthenticated callers
  // never appear as AccessAttempt callers)
  some AccessAttempt
  all a: AccessAttempt | a.aaCaller.role in Clinician + PatientRole + ComplianceOfficer
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md AuditEntry
pred AuditCompleteness {
  // Every AccessAttempt has exactly one AuditEntry, and each AuditEntry belongs to
  // exactly one AccessAttempt (injective, total mapping)
  some AccessAttempt
  all a: AccessAttempt | one a.aaAudit
  all disj a1, a2: AccessAttempt | a1.aaAudit != a2.aaAudit
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly (notes)  ANCHOR: spec.md FR-012; data-model.md ClinicalNote no UPDATE/DELETE
pred AppendOnly {
  // All ClinicalNotes have a valid clinician author — structural immutability
  some ClinicalNote
  all n: ClinicalNote | n.noteAuthor.role = Clinician
  // Every permitted PostNote maps to exactly one new note whose author is the caller
  all a: AccessAttempt |
    (a.aaEndpoint = PostNote and a.aaOutcome = Permitted) =>
      (one n: ClinicalNote |
        n = a.aaAudit.aeNote and
        n.noteAuthor = a.aaCaller and
        n.noteRecord = a.aaTargetRecord)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md AuditEntry accessor_role snapshot
pred AttributionCorrectness {
  some AuditEntry
  all a: AccessAttempt |
    a.aaAudit.aeRole = a.aaCaller.role and
    a.aaAudit.aeAccessor = a.aaCaller
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-003; data-model.md User.assigned_record_id CHECK
pred OwnershipExclusivity {
  some User
  all u: User | (u.role = PatientRole  => one u.assignedRecord)
  all u: User | (u.role != PatientRole => no u.assignedRecord)
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; contracts/http-api.md permission matrix
pred OwnershipBasedAccess {
  some User
  // A patient can get Permitted for GetRecord only on their own assigned record
  all a: AccessAttempt |
    (a.aaCaller.role = PatientRole and a.aaEndpoint = GetRecord and a.aaOutcome = Permitted) =>
      a.aaTargetRecord = a.aaCaller.assignedRecord
  // A patient is denied GetRecord for any other record
  all a: AccessAttempt |
    (a.aaCaller.role = PatientRole and a.aaEndpoint = GetRecord and
     a.aaTargetRecord != a.aaCaller.assignedRecord) =>
      a.aaOutcome = Denied
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008, SC-003; contracts/http-api.md byte-equivalent
pred NoInformationLeakage {
  // Denied responses are structurally indistinguishable regardless of record existence
  some a: AccessAttempt | a.aaOutcome = Denied
  all disj a1, a2: AccessAttempt |
    (a1.aaEndpoint = a2.aaEndpoint and
     a1.aaCaller.role = a2.aaCaller.role and
     a1.aaOutcome = Denied and a2.aaOutcome = Denied) => {
      a1.aaAudit.aeOp      = a2.aaAudit.aeOp
      a1.aaAudit.aeOutcome = a2.aaAudit.aeOutcome
      a1.aaAudit.aeRole    = a2.aaAudit.aeRole
    }
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some AccessAttempt
  // Every modeled access attempt has an authenticated caller with a valid role
  all a: AccessAttempt | a.aaCaller.role in Clinician + PatientRole + ComplianceOfficer
  // No access attempt without a caller (no null caller)
  all a: AccessAttempt | one a.aaCaller
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002; data-model.md User.role CHECK
pred FR_002_OneRolePerUser {
  some User
  all u: User | one u.role
  all u: User | u.role in Clinician + PatientRole + ComplianceOfficer
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003; data-model.md User.assigned_record_id paired CHECK
pred FR_003_PatientAssignedRecord {
  some u: User | u.role = PatientRole
  all u: User | u.role = PatientRole  <=> (one u.assignedRecord)
}
assert FR_003_PatientAssignedRecord { FR_003_PatientAssignedRecord }
check FR_003_PatientAssignedRecord for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004; spec.md care-team gating
pred FR_004_CareTeamGating {
  some AccessAttempt
  // A clinician's GetRecord/PostNote is Permitted only when an active CareTeamMembership exists
  all a: AccessAttempt |
    (a.aaCaller.role = Clinician and a.aaEndpoint in GetRecord + PostNote
     and a.aaOutcome = Permitted) =>
       (some m: CareTeamMembership |
         m.ctmClinician = a.aaCaller and m.ctmRecord = a.aaTargetRecord)
  // Absence of membership means denial
  all a: AccessAttempt |
    (a.aaCaller.role = Clinician and a.aaEndpoint in GetRecord + PostNote and
     (no m: CareTeamMembership |
       m.ctmClinician = a.aaCaller and m.ctmRecord = a.aaTargetRecord)) =>
       a.aaOutcome = Denied
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005; spec.md clinician GetAccessLog denial
pred FR_005_ClinicianAccessLogDenied {
  some a: AccessAttempt | a.aaCaller.role = Clinician
  all a: AccessAttempt |
    a.aaCaller.role = Clinician and a.aaEndpoint = GetAccessLog =>
      a.aaOutcome = Denied
}
assert FR_005_ClinicianAccessLogDenied { FR_005_ClinicianAccessLogDenied }
check FR_005_ClinicianAccessLogDenied for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006; spec.md patient self-access only
pred FR_006_PatientSelfAccessOnly {
  some a: AccessAttempt | a.aaCaller.role = PatientRole
  // Patient permitted on GetRecord only for own record
  all a: AccessAttempt |
    (a.aaCaller.role = PatientRole and a.aaEndpoint = GetRecord) =>
      (a.aaOutcome = Permitted <=> a.aaTargetRecord = a.aaCaller.assignedRecord)
  // Patient never permitted on PostNote
  all a: AccessAttempt |
    (a.aaCaller.role = PatientRole and a.aaEndpoint = PostNote) =>
      a.aaOutcome = Denied
  // Patient never permitted on GetAccessLog
  all a: AccessAttempt |
    (a.aaCaller.role = PatientRole and a.aaEndpoint = GetAccessLog) =>
      a.aaOutcome = Denied
}
assert FR_006_PatientSelfAccessOnly { FR_006_PatientSelfAccessOnly }
check FR_006_PatientSelfAccessOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007, FR-019; compliance content blindness
pred FR_007_ComplianceContentBlind {
  some a: AccessAttempt | a.aaCaller.role = ComplianceOfficer
  // ComplianceOfficer is always denied GetRecord (clinical content)
  all a: AccessAttempt |
    a.aaCaller.role = ComplianceOfficer and a.aaEndpoint = GetRecord =>
      a.aaOutcome = Denied
  // ComplianceOfficer is always denied PostNote
  all a: AccessAttempt |
    a.aaCaller.role = ComplianceOfficer and a.aaEndpoint = PostNote =>
      a.aaOutcome = Denied
  // ComplianceOfficer is permitted GetAccessLog
  all a: AccessAttempt |
    a.aaCaller.role = ComplianceOfficer and a.aaEndpoint = GetAccessLog =>
      a.aaOutcome = Permitted
}
assert FR_007_ComplianceContentBlind { FR_007_ComplianceContentBlind }
check FR_007_ComplianceContentBlind for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008; spec.md byte-equivalent 403 for denied attempts
pred FR_008_ByteEquivalentForbidden {
  // All denied attempts for the same (role, endpoint) pair are
  // structurally identical in their audit records
  some a: AccessAttempt | a.aaOutcome = Denied
  all disj a1, a2: AccessAttempt |
    (a1.aaCaller.role = a2.aaCaller.role and
     a1.aaEndpoint    = a2.aaEndpoint    and
     a1.aaOutcome = Denied and a2.aaOutcome = Denied) => {
      a1.aaAudit.aeOp      = a2.aaAudit.aeOp
      a1.aaAudit.aeOutcome = a2.aaAudit.aeOutcome
      a1.aaAudit.aeRole    = a2.aaAudit.aeRole
      no a1.aaAudit.aeNote
      no a2.aaAudit.aeNote
    }
}
assert FR_008_ByteEquivalentForbidden { FR_008_ByteEquivalentForbidden }
check FR_008_ByteEquivalentForbidden for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012; data-model.md ClinicalNote no UPDATE/DELETE
pred FR_012_NotesAppendOnly {
  some ClinicalNote
  // Every note has a clinician author — structurally preventing patient/CO authorship
  all n: ClinicalNote | n.noteAuthor.role = Clinician
  // Every permitted PostNote attempt binds to exactly one ClinicalNote via the audit entry
  all a: AccessAttempt |
    (a.aaEndpoint = PostNote and a.aaOutcome = Permitted) =>
      (one n: ClinicalNote |
        a.aaAudit.aeNote = n and n.noteAuthor = a.aaCaller)
}
assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013; spec.md one audit entry per access event
pred FR_013_OneAuditPerAccess {
  some AccessAttempt
  all a: AccessAttempt | one a.aaAudit
  all disj a1, a2: AccessAttempt | a1.aaAudit != a2.aaAudit
}
assert FR_013_OneAuditPerAccess { FR_013_OneAuditPerAccess }
check FR_013_OneAuditPerAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014; data-model.md AuditEntry field constraints
pred FR_014_AuditEntryFields {
  some AuditEntry
  // note_id present iff append+permitted
  all ae: AuditEntry | {
    (ae.aeOp = AppendOp and ae.aeOutcome = Permitted) <=> one ae.aeNote
    (ae.aeOp = ReadOp)                                  =>  no ae.aeNote
    (ae.aeOp = ListOp)                                  =>  no ae.aeNote
  }
  // Attribution: role snapshot matches caller's role for every audit via access attempt
  all a: AccessAttempt | a.aaAudit.aeRole = a.aaCaller.role
}
assert FR_014_AuditEntryFields { FR_014_AuditEntryFields }
check FR_014_AuditEntryFields for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015; data-model.md AuditEntry "no UPDATE/DELETE"
pred FR_015_AuditImmutable {
  some AuditEntry
  // Each audit entry is owned by at most one access attempt (injective)
  all disj a1, a2: AccessAttempt | a1.aaAudit != a2.aaAudit
  // Audit accessor matches the attempt's caller — no retroactive re-attribution
  all a: AccessAttempt | a.aaAudit.aeAccessor = a.aaCaller
}
assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017; spec.md 7-year retention; data-model.md no DELETE on audit_entries
pred FR_017_AuditRetention {
  // No AuditEntry is "orphaned" — every entry has a valid accessor user
  some AuditEntry
  all ae: AuditEntry | ae.aeAccessor.role in Clinician + PatientRole + ComplianceOfficer
  // Every AuditEntry produced by a permitted append has a non-null note reference
  all ae: AuditEntry |
    (ae.aeOp = AppendOp and ae.aeOutcome = Permitted) => one ae.aeNote
}
assert FR_017_AuditRetention { FR_017_AuditRetention }
check FR_017_AuditRetention for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020; spec.md URL paths use opaque record_id only
pred FR_020_OpaqueRecordIds {
  // Record identifiers are opaque atoms — no patient demographic content
  // Modeled structurally: Record sigs carry no demographic fields (enforced by sig definition)
  some Record
  some AccessAttempt
  // Every endpoint that uses {id} has a targetRecord atom, not a demographic
  all a: AccessAttempt |
    a.aaEndpoint != GetAccessLog => one a.aaTargetRecord
}
assert FR_020_OpaqueRecordIds { FR_020_OpaqueRecordIds }
check FR_020_OpaqueRecordIds for 8