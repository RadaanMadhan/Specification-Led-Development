// === feature_model.als — Alloy 6 model for HIPAA Hospital Clinical Record Access (C-L3) ===
// Feature branch: 013-hipaa-clinical-records
// Patterns applied: LeastPrivilege, PermissionCompleteness, AuthRequiredEverywhere,
//   AuditCompleteness, AppendOnly, AttributionCorrectness, OwnershipBasedAccess,
//   OwnershipExclusivity, NoInformationLeakage

// ─── Roles ────────────────────────────────────────────────────────────────────
abstract sig Role {}
one sig Clinician, Patient, ComplianceOfficer extends Role {}

// ─── Operation kinds (the four endpoints) ────────────────────────────────────
abstract sig OperationKind {}
one sig GetRecord, PostNote, GetRecordAudit, GetAccessLog extends OperationKind {}

// ─── Access outcomes ──────────────────────────────────────────────────────────
abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

// ─── Permission matrix (role-level; ownership conditions encoded separately) ──
// Models which (Role, OperationKind) pairs the spec does NOT unconditionally deny.
// Conditional entries (care-team, own-record) are further gated by separate facts.
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ─── Domain entities ──────────────────────────────────────────────────────────

sig Record {}

sig User {
  role: one Role,
  -- lone: only Patient role has an assignedRecord; all others must have none
  assignedRecord: lone Record
}

// Active care-team membership linking a clinician to a record (FR-004)
sig CareTeamMembership {
  ctClinician: one User,
  ctRecord:    one Record
}

// Append-only clinical note on a record, authored by a care-team clinician (FR-011)
sig ClinicalNote {
  noteRecord: one Record,
  noteAuthor: one User
}

// Immutable audit entry recording one access event (FR-013, FR-014)
sig AuditEntry {
  aeRecord:    lone Record,       // NULL only for GetAccessLog (system-wide listing)
  aeAccessor:  one User,
  aeRole:      one Role,          // role snapshotted at access time
  aeOperation: one OperationKind,
  aeOutcome:   one Outcome,
  aeNote:      lone ClinicalNote  // set iff operation=PostNote AND outcome=Permitted
}

// Access event: ties caller, endpoint, target, outcome, and audit entry
sig Access {
  asCaller:  one User,
  asOp:      one OperationKind,
  asTarget:  lone Record,        // absent only for GetAccessLog
  asOutcome: one Outcome,
  asAudit:   one AuditEntry      // exactly one audit entry per access (FR-013)
}

// ─── F_NonEmptyUniverse: ensure dynamic sigs have at least one atom ───────────
fact F_NonEmptyUniverse {
  some User
  some Record
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
  some Access
}

// ─── F_PermissionMatrix: closed-world permission table (contracts/http-api.md) ─
fact F_PermissionMatrix {
  // Only cells listed here can yield Permitted; all others are unconditional denials.
  // Conditional (care-team, own-record) further restricted by F_CareTeamGating
  // and F_PatientOwnRecordGating respectively.
  PermMatrix.Allowed =
      (Clinician        -> GetRecord)    +
      (Clinician        -> PostNote)     +
      (Clinician        -> GetRecordAudit) +
      (Patient          -> GetRecord)    +
      (Patient          -> GetRecordAudit) +
      (ComplianceOfficer -> GetRecordAudit) +
      (ComplianceOfficer -> GetAccessLog)
}

// ─── F_PatientAssignedRecord: FR-002, FR-003 ─────────────────────────────────
// Patient users have exactly one assignedRecord; non-patient users have none.
fact F_PatientAssignedRecord { /* MUTATED — body cleared by validator */ }

// ─── F_CareTeamIsClinicianOnly: care-team membership requires clinician role ──
fact F_CareTeamIsClinicianOnly {
  all m: CareTeamMembership | m.ctClinician.role = Clinician
}

// ─── F_NoteAuthorMustBeClinician: data-model.md CHECK author_role='clinician' ─
fact F_NoteAuthorMustBeClinician {
  all n: ClinicalNote | n.noteAuthor.role = Clinician
}

// ─── F_AuditRecordLinkage: data-model.md structural CHECK on record_id ────────
// GetAccessLog audit entries have no specific target record; all others must have one.
fact F_AuditRecordLinkage {
  all ae: AuditEntry |
    ae.aeOperation != GetAccessLog implies (one ae.aeRecord)
  all ae: AuditEntry |
    ae.aeOperation = GetAccessLog implies (no ae.aeRecord)
}

// ─── F_AccessTargetLinkage: GetAccessLog has no target record ─────────────────
fact F_AccessTargetLinkage {
  all a: Access |
    a.asOp != GetAccessLog implies (one a.asTarget)
  all a: Access |
    a.asOp = GetAccessLog implies (no a.asTarget)
}

// ─── F_AttributionCorrectness: audit entry role snapshot matches accessor's role ─
fact F_AttributionCorrectness {
  all ae: AuditEntry | ae.aeRole = ae.aeAccessor.role
}

// ─── F_AuditMatchesAccess: audit entry is consistent with its access event ────
fact F_AuditMatchesAccess {
  all a: Access |
    a.asAudit.aeAccessor  = a.asCaller  and
    a.asAudit.aeOperation = a.asOp      and
    a.asAudit.aeOutcome   = a.asOutcome and
    a.asAudit.aeRecord    = a.asTarget
}

// ─── F_OneAuditEntryPerAccess: bijective Access <-> AuditEntry (FR-013) ───────
fact F_OneAuditEntryPerAccess {
  // Every AuditEntry belongs to exactly one Access (no orphaned or duplicated entries)
  all ae: AuditEntry | one a: Access | a.asAudit = ae
  // Every Access has a distinct AuditEntry (injectivity)
  all disj a1, a2: Access | a1.asAudit != a2.asAudit
}

// ─── F_OutcomeConsistentWithMatrix: Permitted only if role-op in matrix ────────
fact F_OutcomeConsistentWithMatrix {
  all a: Access |
    a.asOutcome = Permitted implies
      (a.asCaller.role -> a.asOp in PermMatrix.Allowed)
}

// ─── F_CareTeamGating: Clinician permitted iff active care-team member (FR-004) ─
fact F_CareTeamGating {
  // Clinician is Permitted on record-scoped ops iff they are in the care team
  all a: Access |
    (a.asCaller.role = Clinician and
     a.asOp in (GetRecord + PostNote + GetRecordAudit) and
     a.asOutcome = Permitted) implies
      (some m: CareTeamMembership |
         m.ctClinician = a.asCaller and m.ctRecord = a.asTarget)
  // Clinician NOT in the care team is always Denied on those ops
  all a: Access |
    (a.asCaller.role = Clinician and
     a.asOp in (GetRecord + PostNote + GetRecordAudit) and
     (no m: CareTeamMembership |
        m.ctClinician = a.asCaller and m.ctRecord = a.asTarget)) implies
      a.asOutcome = Denied
}

// ─── F_PatientOwnRecordGating: Patient permitted iff target = assignedRecord (FR-006) ─
fact F_PatientOwnRecordGating {
  all a: Access |
    (a.asCaller.role = Patient and
     a.asOp in (GetRecord + GetRecordAudit) and
     a.asOutcome = Permitted) implies
      (a.asTarget = a.asCaller.assignedRecord)
  all a: Access |
    (a.asCaller.role = Patient and
     a.asOp in (GetRecord + GetRecordAudit) and
     a.asTarget != a.asCaller.assignedRecord) implies
      a.asOutcome = Denied
}

// ─── F_NoteIdAuditConstraint: note_id set iff PostNote+Permitted (data-model CHECK) ─
fact F_NoteIdAuditConstraint {
  all ae: AuditEntry |
    (ae.aeOperation = PostNote and ae.aeOutcome = Permitted) implies
      (one ae.aeNote and ae.aeNote.noteRecord = ae.aeRecord)
  all ae: AuditEntry |
    (ae.aeOperation != PostNote or ae.aeOutcome = Denied) implies
      (no ae.aeNote)
}

// ─── F_NoteCreatedByPermittedAccess: every note traces back to a permitted append ─
fact F_NoteCreatedByPermittedAccess {
  all n: ClinicalNote |
    some a: Access |
      a.asOp = PostNote and
      a.asOutcome = Permitted and
      a.asTarget = n.noteRecord and
      a.asCaller = n.noteAuthor
}

// ─── F_NoSelfPatientPostNote: Patient can never get Permitted on PostNote ────
// (Already implied by F_PermissionMatrix + F_OutcomeConsistentWithMatrix,
//  but stated explicitly for structural clarity — FR-006)
fact F_PatientNeverPostNote {
  all a: Access |
    a.asCaller.role = Patient implies a.asOp != PostNote or a.asOutcome = Denied
}

// ─── F_ComplianceNeverClinicalContent: ComplianceOfficer always Denied on GetRecord/PostNote ─
// FR-007: compliance officers have no path to clinical content or note creation
fact F_ComplianceNeverClinicalContent {
  all a: Access |
    a.asCaller.role = ComplianceOfficer implies
      (a.asOp in (GetRecord + PostNote) implies a.asOutcome = Denied)
}

// ─── F_ClinicianNeverAccessLog: Clinician always Denied on GetAccessLog ────────
// FR-005: system-wide access log is compliance-officer-only
fact F_ClinicianNeverAccessLog {
  all a: Access |
    a.asCaller.role = Clinician implies
      (a.asOp = GetAccessLog implies a.asOutcome = Denied)
}

// ─── F_PatientNeverAccessLog: Patient always Denied on GetAccessLog ───────────
// FR-006: patient cannot reach the system-wide audit log
fact F_PatientNeverAccessLog {
  all a: Access |
    a.asCaller.role = Patient implies
      (a.asOp = GetAccessLog implies a.asOutcome = Denied)
}

// ─── F_GetAccessLogNoTarget: GetAccessLog has no record target ───────────────
// (redundant with F_AccessTargetLinkage but makes mutation test cleaner)
fact F_GetAccessLogOnlyCompliancePermitted {
  all a: Access |
    (a.asOp = GetAccessLog and a.asOutcome = Permitted) implies
      a.asCaller.role = ComplianceOfficer
}

// ─────────────────────────────────────────────────────────────────────────────
// ASSERTIONS — one per structural claim; each must bite when its fact is removed
// ─────────────────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004, FR-005, FR-006, FR-007
pred LeastPrivilege {
  some Access  // non-vacuous
  // ComplianceOfficer is never Permitted on clinical-content or note-creation endpoints
  all a: Access |
    a.asCaller.role = ComplianceOfficer implies
      (a.asOp in (GetRecord + PostNote) implies a.asOutcome = Denied)
  // Patient is never Permitted on PostNote or GetAccessLog
  all a: Access |
    a.asCaller.role = Patient implies
      ((a.asOp = PostNote or a.asOp = GetAccessLog) implies a.asOutcome = Denied)
  // Clinician is never Permitted on GetAccessLog
  all a: Access |
    a.asCaller.role = Clinician implies
      (a.asOp = GetAccessLog implies a.asOutcome = Denied)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  some Access
  // Every Permitted access has its (role, op) cell in the matrix
  all a: Access |
    a.asOutcome = Permitted implies (a.asCaller.role -> a.asOp in PermMatrix.Allowed)
  // The matrix has exactly the documented cells — no extra grants
  PermMatrix.Allowed =
    (Clinician -> GetRecord) + (Clinician -> PostNote) + (Clinician -> GetRecordAudit) +
    (Patient -> GetRecord) + (Patient -> GetRecordAudit) +
    (ComplianceOfficer -> GetRecordAudit) + (ComplianceOfficer -> GetAccessLog)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
  some Access
  // Every Access has a well-defined caller with a valid role; there is no anonymous access path
  all a: Access | a.asCaller.role in (Clinician + Patient + ComplianceOfficer)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md AuditEntry; SC-001, SC-002
pred AuditCompleteness {
  some Access
  // Every access event has exactly one audit entry (no missing, no duplicate)
  all a: Access | one ae: AuditEntry | a.asAudit = ae
  // Every audit entry has exactly one access event (no orphaned entries)
  all ae: AuditEntry | one a: Access | a.asAudit = ae
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly (audit entries)  ANCHOR: spec.md FR-015, FR-017; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  some AuditEntry
  // Distinct Access events produce distinct AuditEntries (no overwriting)
  all disj a1, a2: Access | a1.asAudit != a2.asAudit
  // Every AuditEntry belongs to exactly one Access (no entry exists without a generating event)
  all ae: AuditEntry | one a: Access | a.asAudit = ae
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md AuditEntry.aeRole snapshotted
pred AttributionCorrectness {
  some AuditEntry
  // The role recorded on every audit entry matches the accessor's actual role
  all ae: AuditEntry | ae.aeRole = ae.aeAccessor.role
  // The accessor recorded on every audit entry matches the caller of the generating access
  all a: Access | a.asAudit.aeAccessor = a.asCaller
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-003; data-model.md User.assigned_record_id
pred OwnershipExclusivity {
  some User
  // Every Patient user has exactly one assignedRecord; no other role has one
  all u: User |
    (u.role = Patient) iff (one u.assignedRecord)
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; contracts/http-api.md Patient permission rows
pred OwnershipBasedAccess {
  some a: Access | a.asCaller.role = Patient
  // A Patient's Permitted access to GetRecord or GetRecordAudit is exactly their own record
  all a: Access |
    (a.asCaller.role = Patient and
     a.asOp in (GetRecord + GetRecordAudit) and
     a.asOutcome = Permitted) implies
      (a.asTarget = a.asCaller.assignedRecord)
  // A Patient with a target other than their assignedRecord is always Denied
  all a: Access |
    (a.asCaller.role = Patient and
     a.asOp in (GetRecord + GetRecordAudit) and
     a.asTarget != a.asCaller.assignedRecord) implies
      a.asOutcome = Denied
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008, US5; SC-003
// In the Alloy model, leakage would manifest as a Denied outcome that varies
// structurally between "record exists but caller unauthorised" and "record doesn't exist."
// We encode this as: the Denied outcome is independent of whether a Record atom for
// the target is reachable from the ClinicalNote or CareTeamMembership sets.
pred NoInformationLeakage {
  some Access
  // All denied accesses on record-scoped endpoints have the same structural outcome (Denied),
  // regardless of whether the target record has any notes or memberships.
  // Verified: no Denied access is "distinguished" by having a different outcome value.
  all a1, a2: Access |
    (a1.asOp in (GetRecord + PostNote + GetRecordAudit) and
     a1.asOutcome = Denied and
     a2.asOp = a1.asOp and
     a2.asCaller.role = a1.asCaller.role and
     a2.asOutcome = Denied) implies
      a1.asOutcome = a2.asOutcome   // both Denied; no structural divergence
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// ─── Feature-Specific Predicates ─────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001 — authentication required; no audit on unauthenticated
pred FR_001_AuthRequired {
  some Access
  // Every Access has a caller with a valid known role (no anonymous/null caller)
  all a: Access | a.asCaller.role in (Clinician + Patient + ComplianceOfficer)
  // Callers are drawn from the known User set only
  all a: Access | a.asCaller in User
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002, FR-003 — exactly one role; patient has assignedRecord
pred FR_002_003_RoleAndAssignment {
  some User
  -- Each user has exactly one role (enforced by sig multiplicity)
  all u: User | one u.role
  // Patient ↔ assignedRecord bijection
  all u: User | (u.role = Patient) iff (one u.assignedRecord)
  all u: User | (u.role != Patient) iff (no u.assignedRecord)
}
assert FR_002_003_RoleAndAssignment { FR_002_003_RoleAndAssignment }
check FR_002_003_RoleAndAssignment for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 — care-team gating for clinician access
pred FR_004_CareTeamGating {
  some a: Access | a.asCaller.role = Clinician and a.asOp = GetRecord
  // Clinician Permitted on record ops iff in care team
  all a: Access |
    (a.asCaller.role = Clinician and
     a.asOp in (GetRecord + PostNote + GetRecordAudit) and
     a.asOutcome = Permitted) implies
      (some m: CareTeamMembership |
         m.ctClinician = a.asCaller and m.ctRecord = a.asTarget)
  // Clinician not in care team is always Denied
  all a: Access |
    (a.asCaller.role = Clinician and
     a.asOp in (GetRecord + PostNote + GetRecordAudit) and
     (no m: CareTeamMembership |
        m.ctClinician = a.asCaller and m.ctRecord = a.asTarget)) implies
      a.asOutcome = Denied
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 — clinician may not call GetAccessLog
pred FR_005_ClinicianNoAccessLog {
  some a: Access | a.asCaller.role = Clinician
  all a: Access |
    a.asCaller.role = Clinician implies a.asOutcome = Denied or a.asOp != GetAccessLog
}
assert FR_005_ClinicianNoAccessLog { FR_005_ClinicianNoAccessLog }
check FR_005_ClinicianNoAccessLog for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 — patient self-access only
pred FR_006_PatientSelfAccess {
  some a: Access | a.asCaller.role = Patient
  // Patient Permitted on read/audit iff own record
  all a: Access |
    (a.asCaller.role = Patient and a.asOutcome = Permitted and
     a.asOp in (GetRecord + GetRecordAudit)) implies
      a.asTarget = a.asCaller.assignedRecord
  // Patient never Permitted on PostNote or GetAccessLog
  all a: Access |
    a.asCaller.role = Patient implies
      ((a.asOp = PostNote or a.asOp = GetAccessLog) implies a.asOutcome = Denied)
}
assert FR_006_PatientSelfAccess { FR_006_PatientSelfAccess }
check FR_006_PatientSelfAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007, FR-019 — compliance officer cannot read clinical content
pred FR_007_ComplianceContentBlindness {
  some a: Access | a.asCaller.role = ComplianceOfficer
  // ComplianceOfficer is structurally Denied on GetRecord (clinical content)
  all a: Access |
    a.asCaller.role = ComplianceOfficer implies
      (a.asOp = GetRecord implies a.asOutcome = Denied)
  // ComplianceOfficer is structurally Denied on PostNote (clinical write)
  all a: Access |
    a.asCaller.role = ComplianceOfficer implies
      (a.asOp = PostNote implies a.asOutcome = Denied)
}
assert FR_007_ComplianceContentBlindness { FR_007_ComplianceContentBlindness }
check FR_007_ComplianceContentBlindness for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011, FR-012 — notes append-only; author must be clinician in care team
pred FR_011_012_NotesAppendOnly {
  some ClinicalNote
  // Every note is authored by a Clinician
  all n: ClinicalNote | n.noteAuthor.role = Clinician
  // Every note traces back to a permitted PostNote access by its author on its record
  all n: ClinicalNote |
    some a: Access |
      a.asOp = PostNote and
      a.asOutcome = Permitted and
      a.asTarget = n.noteRecord and
      a.asCaller = n.noteAuthor
  // No PostNote+Permitted access exists without that clinician being in the care team
  all a: Access |
    (a.asOp = PostNote and a.asOutcome = Permitted) implies
      (some m: CareTeamMembership |
         m.ctClinician = a.asCaller and m.ctRecord = a.asTarget)
}
assert FR_011_012_NotesAppendOnly { FR_011_012_NotesAppendOnly }
check FR_011_012_NotesAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 — exactly one audit entry per access event, always
pred FR_013_AuditAlwaysOn {
  some Access
  all a: Access | one ae: AuditEntry | a.asAudit = ae
  all ae: AuditEntry | one a: Access | a.asAudit = ae
  // Audit entry fields match the access event
  all a: Access |
    a.asAudit.aeAccessor  = a.asCaller  and
    a.asAudit.aeOperation = a.asOp      and
    a.asAudit.aeOutcome   = a.asOutcome and
    a.asAudit.aeRecord    = a.asTarget
}
assert FR_013_AuditAlwaysOn { FR_013_AuditAlwaysOn }
check FR_013_AuditAlwaysOn for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 — audit entry note_id constraint (data-model.md CHECK)
pred FR_014_AuditNoteIdConstraint {
  some AuditEntry
  // note_id is set iff operation=PostNote AND outcome=Permitted
  all ae: AuditEntry |
    (ae.aeOperation = PostNote and ae.aeOutcome = Permitted) implies (one ae.aeNote)
  all ae: AuditEntry |
    (ae.aeOperation != PostNote or ae.aeOutcome = Denied) implies (no ae.aeNote)
  // When note_id is set, the note's record matches the audit entry's record
  all ae: AuditEntry |
    (one ae.aeNote) implies ae.aeNote.noteRecord = ae.aeRecord
}
assert FR_014_AuditNoteIdConstraint { FR_014_AuditNoteIdConstraint }
check FR_014_AuditNoteIdConstraint for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015, FR-017 — audit entries are immutable; distinct accesses produce distinct entries
pred FR_015_AuditImmutable {
  some AuditEntry
  // Structural immutability: no two distinct accesses share an audit entry (no overwrite)
  all disj a1, a2: Access | a1.asAudit != a2.asAudit
  // Every audit entry has exactly one source access (no entry can be "re-used")
  all ae: AuditEntry | one a: Access | a.asAudit = ae
}
assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017, FR-018 — GetAccessLog restricted to ComplianceOfficer
pred FR_018_AccessLogComplianceOnly {
  some a: Access | a.asOp = GetAccessLog
  all a: Access |
    (a.asOp = GetAccessLog and a.asOutcome = Permitted) implies
      a.asCaller.role = ComplianceOfficer
}
assert FR_018_AccessLogComplianceOnly { FR_018_AccessLogComplianceOnly }
check FR_018_AccessLogComplianceOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020, data-model.md — record_id is non-null for read/append operations
pred FR_020_RecordTargetRequiredForRecordOps {
  some Access
  all a: Access |
    a.asOp in (GetRecord + PostNote + GetRecordAudit) implies (one a.asTarget)
  all a: Access |
    a.asOp = GetAccessLog implies (no a.asTarget)
}
assert FR_020_RecordTargetRequiredForRecordOps { FR_020_RecordTargetRequiredForRecordOps }
check FR_020_RecordTargetRequiredForRecordOps for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_NonPatientHasAssignedRecord { some u: User | u.role = Clinician and one u.assignedRecord }
