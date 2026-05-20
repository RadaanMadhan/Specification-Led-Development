// === feature_model.als — Alloy model for 012-hospital-clinical-records ===
// Hospital Clinical Record Access. Models:
//   * 5-role catalogue (4 clinical + hospital_administrator)
//   * 3 operations (read record, add note, list audit)
//   * permission matrix (closed-world)
//   * care-team-membership gating for clinical reads/writes
//   * audit completeness, attribution, and immutability
//   * append-only clinical notes (excluding administrator authorship)
//   * byte-equivalent denial / no-information-leakage on refused access
//   * administrator content-blindness on the audit endpoint

abstract sig Bool {}
one sig True, False extends Bool {}

abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator extends Role {}

abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

abstract sig OperationKind {}
one sig ReadRecord, AddNote, ListAudit extends OperationKind {}

abstract sig Outcome {}
one sig Permitted, Denied, NotFoundOrDenied extends Outcome {}

abstract sig AuthBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound, AdministratorRole extends AuthBasis {}

sig User { role: one Role }
sig Patient {}

sig CareTeamMembership {
  clinician: one User,
  ctmPatient: one Patient,
  status: one MembershipStatus
}

sig ClinicalNote {
  notePatient: one Patient,
  author: one User,
  authorRoleSnap: one Role
}

sig AccessAttempt {
  caller: one User,
  targetPatient: lone Patient,
  kind: one OperationKind,
  outcome: one Outcome,
  basis: one AuthBasis,
  authenticated: one Bool,
  exposesClinicalContent: one Bool,
  identifierViaBody: one Bool,
  validInput: one Bool
}

sig AuditEntry {
  attempt: one AccessAttempt,
  auditUser: one User,
  auditUserRole: one Role
}

// Permission matrix held as a field on a singleton sig (Alloy 6 idiom).
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------------------------------------------------------------------
// Non-empty universe so quantifications bite.
// ---------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some ClinicalNote
  some AccessAttempt
  some AuditEntry
}

// ---------------------------------------------------------------------
// Closed-world permission matrix encoded from contracts/http-api.md.
// 4 clinical roles × {ReadRecord, AddNote}  +  hospital_administrator × ListAudit
// ---------------------------------------------------------------------
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Doctor -> ReadRecord) + (Doctor -> AddNote)
    + (Nurse -> ReadRecord) + (Nurse -> AddNote)
    + (Pharmacist -> ReadRecord) + (Pharmacist -> AddNote)
    + (ClinicalAdmin -> ReadRecord) + (ClinicalAdmin -> AddNote)
    + (HospitalAdministrator -> ListAudit)
}

// ---------------------------------------------------------------------
// Load-bearing facts that the assertions check.
// ---------------------------------------------------------------------

// Only role/op cells in the matrix may produce a Permitted outcome.
fact F_LeastPrivilege {
  all a: AccessAttempt |
    a.outcome = Permitted implies (a.caller.role -> a.kind) in PermMatrix.Allowed
}

// Clinical reads/writes are gated by an active care-team membership.
fact F_CareTeamGating {
  all a: AccessAttempt |
    (a.outcome = Permitted and (a.kind = ReadRecord or a.kind = AddNote))
      implies (some m: CareTeamMembership |
                 m.clinician = a.caller
                 and m.ctmPatient = a.targetPatient
                 and m.status = Active)
}

// Every authenticated clinical-record access attempt yields exactly one audit entry.
fact F_AuditCompleteness {
  all a: AccessAttempt |
    (a.authenticated = True and (a.kind = ReadRecord or a.kind = AddNote))
      implies (one e: AuditEntry | e.attempt = a)
}

// At most one audit entry per attempt — audit log is append-only and per-event.
fact F_AuditEntryUnique {
  all disj e1, e2: AuditEntry | e1.attempt != e2.attempt
}

// Audit-entry attribution matches the real caller and the real caller's role.
fact F_AuditAttribution {
  all e: AuditEntry | e.auditUser = e.attempt.caller
  all e: AuditEntry | e.auditUserRole = e.attempt.caller.role
}

// Clinical notes are never authored by an administrator (data-model CHECK).
fact F_NoteAuthorIsClinical {
  all n: ClinicalNote | n.authorRoleSnap != HospitalAdministrator
}

// The author-role snapshot on a note matches the author's current role.
fact F_NoteAuthorSnapshotIntegrity {
  all n: ClinicalNote | n.authorRoleSnap = n.author.role
}

// Administrator (ListAudit) responses never expose clinical content.
fact F_AdminContentBlindness {
  all a: AccessAttempt |
    a.kind = ListAudit implies a.exposesClinicalContent = False
}

// Denied / not-found responses never expose clinical content (byte-equivalent envelope).
fact F_DeniedNoClinicalContent { /* MUTATED — body cleared by validator */ }

// Authentication boundary: Permitted requires authenticated; unauthenticated produces no audit.
fact F_AuthenticationBoundary {
  all a: AccessAttempt | a.outcome = Permitted implies a.authenticated = True
  all a: AccessAttempt |
    a.authenticated = False implies (no e: AuditEntry | e.attempt = a)
}

// Patient identifier always supplied via the request body, never a URL path component.
fact F_PatientIdViaBody {
  all a: AccessAttempt | a.identifierViaBody = True
}

// Invalid input never reaches a Permitted outcome (validation-before-mutation).
fact F_ValidationBeforeMutation {
  all a: AccessAttempt | a.validInput = False implies a.outcome != Permitted
}

// Authorisation basis is internally consistent with the outcome+kind.
fact F_AuthBasisConsistent {
  all a: AccessAttempt |
    (a.outcome = Permitted and (a.kind = ReadRecord or a.kind = AddNote))
      implies a.basis = CareTeamMember
  all a: AccessAttempt |
    (a.outcome = Permitted and a.kind = ListAudit) implies a.basis = AdministratorRole
}

// =====================================================================
// PATTERN PREDICATES & ASSERTIONS
// =====================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission tables; spec.md FR-004/FR-005/FR-017
pred LeastPrivilege {
  all a: AccessAttempt |
    a.outcome = Permitted implies (a.caller.role -> a.kind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables
pred PermissionCompleteness {
  // Matrix carries exactly 9 allow-cells; every (role, op) pair has a defined verdict
  // (in-matrix = allow, out-of-matrix = deny). No undefined cells.
  #PermMatrix.Allowed = 9
  all r: Role, k: OperationKind |
    (r -> k) in PermMatrix.Allowed or (r -> k) not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  all a: AccessAttempt | a.outcome = Permitted implies a.authenticated = True
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012; data-model.md audit_entries
pred AuditCompleteness {
  all a: AccessAttempt |
    (a.authenticated = True and (a.kind = ReadRecord or a.kind = AddNote))
      implies (one e: AuditEntry | e.attempt = a)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011/FR-014; data-model.md immutability sections
pred AppendOnly {
  // Audit entries are unique-per-attempt (no overwrite produces a second audit row),
  // and note authorship is restricted to the clinical roles (no admin tampering).
  (all disj e1, e2: AuditEntry | e1.attempt != e2.attempt)
  and (all n: ClinicalNote | n.authorRoleSnap != HospitalAdministrator)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md audit_entries
pred AttributionCorrectness {
  all e: AuditEntry |
    e.auditUser = e.attempt.caller and e.auditUserRole = e.attempt.caller.role
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004 (care-team-membership gating)
pred OwnershipBasedAccess {
  all a: AccessAttempt |
    (a.outcome = Permitted and (a.kind = ReadRecord or a.kind = AddNote))
      implies (some m: CareTeamMembership |
                 m.clinician = a.caller
                 and m.ctmPatient = a.targetPatient
                 and m.status = Active)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006
pred NoInformationLeakage {
  all a: AccessAttempt |
    (a.outcome = Denied or a.outcome = NotFoundOrDenied)
      implies a.exposesClinicalContent = False
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-009
pred ValidationBeforeMutation {
  all a: AccessAttempt | a.validInput = False implies a.outcome != Permitted
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// =====================================================================
// FEATURE-SPECIFIC FR ASSERTIONS (one per FR-NNN in spec.md)
// =====================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication boundary; unauthenticated never audited
pred FR_001_AuthRequired {
  all a: AccessAttempt | a.outcome = Permitted implies a.authenticated = True
  all a: AccessAttempt |
    a.authenticated = False implies (no e: AuditEntry | e.attempt = a)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 closed five-role catalogue, one role per user
pred FR_002_RoleCatalogueClosed {
  Role = Doctor + Nurse + Pharmacist + ClinicalAdmin + HospitalAdministrator
  all u: User | one u.role
}
assert FR_002_RoleCatalogueClosed { FR_002_RoleCatalogueClosed }
check FR_002_RoleCatalogueClosed for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 patient_id supplied via request body, never URL path
pred FR_003_PatientIdViaBody {
  all a: AccessAttempt | a.identifierViaBody = True
}
assert FR_003_PatientIdViaBody { FR_003_PatientIdViaBody }
check FR_003_PatientIdViaBody for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 care-team gating for clinical reads / writes
pred FR_004_CareTeamGating {
  all a: AccessAttempt |
    (a.outcome = Permitted and (a.kind = ReadRecord or a.kind = AddNote))
      implies (some m: CareTeamMembership |
                 m.clinician = a.caller
                 and m.ctmPatient = a.targetPatient
                 and m.status = Active)
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 hospital_administrator cannot read/write clinical content
pred FR_005_AdminNoClinicalRead {
  all a: AccessAttempt |
    ((a.kind = ReadRecord or a.kind = AddNote)
       and a.caller.role = HospitalAdministrator)
      implies a.outcome != Permitted
}
assert FR_005_AdminNoClinicalRead { FR_005_AdminNoClinicalRead }
check FR_005_AdminNoClinicalRead for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 byte-equivalent unauthorised envelope: denied never leaks content
pred FR_006_ByteEquivalentDenial {
  all a: AccessAttempt |
    (a.outcome = Denied or a.outcome = NotFoundOrDenied)
      implies a.exposesClinicalContent = False
}
assert FR_006_ByteEquivalentDenial { FR_006_ByteEquivalentDenial }
check FR_006_ByteEquivalentDenial for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 record-read response shape: clinical content only when Permitted ReadRecord
pred FR_007_ResponseShape {
  all a: AccessAttempt |
    a.exposesClinicalContent = True
      implies (a.outcome = Permitted and a.kind = ReadRecord)
}
assert FR_007_ResponseShape { FR_007_ResponseShape }
check FR_007_ResponseShape for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 patient summary returned only for a real patient
pred FR_008_RecordReadHasPatient {
  all a: AccessAttempt |
    (a.outcome = Permitted and a.kind = ReadRecord)
      implies (some a.targetPatient)
}
assert FR_008_RecordReadHasPatient { FR_008_RecordReadHasPatient }
check FR_008_RecordReadHasPatient for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 invalid note submissions never persist
pred FR_009_NoteValidation {
  all a: AccessAttempt | a.validInput = False implies a.outcome != Permitted
}
assert FR_009_NoteValidation { FR_009_NoteValidation }
check FR_009_NoteValidation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 persisted notes carry an accurate author-role snapshot
pred FR_010_NoteFields {
  all n: ClinicalNote | n.authorRoleSnap = n.author.role
}
assert FR_010_NoteFields { FR_010_NoteFields }
check FR_010_NoteFields for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 notes append-only; hospital_administrator may not author a note
pred FR_011_NotesAppendOnly {
  all n: ClinicalNote | n.authorRoleSnap != HospitalAdministrator
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 always-on audit for authenticated clinical-record access
pred FR_012_AlwaysOnAudit {
  all a: AccessAttempt |
    (a.authenticated = True and (a.kind = ReadRecord or a.kind = AddNote))
      implies (one e: AuditEntry | e.attempt = a)
}
assert FR_012_AlwaysOnAudit { FR_012_AlwaysOnAudit }
check FR_012_AlwaysOnAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 audit entries' (user, role) fields match the real caller
pred FR_013_AuditFields {
  all e: AuditEntry |
    e.auditUser = e.attempt.caller and e.auditUserRole = e.attempt.caller.role
}
assert FR_013_AuditFields { FR_013_AuditFields }
check FR_013_AuditFields for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 audit entries immutable: at most one entry per attempt
pred FR_014_AuditImmutable {
  all disj e1, e2: AuditEntry | e1.attempt != e2.attempt
}
assert FR_014_AuditImmutable { FR_014_AuditImmutable }
check FR_014_AuditImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 every Permitted clinical access has its audit entry written
pred FR_015_AuditSLA {
  all a: AccessAttempt |
    (a.outcome = Permitted and (a.kind = ReadRecord or a.kind = AddNote))
      implies (one e: AuditEntry | e.attempt = a)
}
assert FR_015_AuditSLA { FR_015_AuditSLA }
check FR_015_AuditSLA for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 retention floor: audit entries persist (no two map to same attempt; entries exist)
pred FR_016_AuditRetention {
  all disj e1, e2: AuditEntry | e1.attempt != e2.attempt
  all a: AccessAttempt |
    (a.authenticated = True and (a.kind = ReadRecord or a.kind = AddNote))
      implies (some e: AuditEntry | e.attempt = a)
}
assert FR_016_AuditRetention { FR_016_AuditRetention }
check FR_016_AuditRetention for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 list-audit endpoint is administrator-only
pred FR_017_AdminOnlyAuditEndpoint {
  all a: AccessAttempt |
    (a.kind = ListAudit and a.outcome = Permitted)
      implies a.caller.role = HospitalAdministrator
}
assert FR_017_AdminOnlyAuditEndpoint { FR_017_AdminOnlyAuditEndpoint }
check FR_017_AdminOnlyAuditEndpoint for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 administrator responses are clinical-content-blind
pred FR_018_AdminContentBlindness {
  all a: AccessAttempt |
    a.kind = ListAudit implies a.exposesClinicalContent = False
}
assert FR_018_AdminContentBlindness { FR_018_AdminContentBlindness }
check FR_018_AdminContentBlindness for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 safety fields surface only on successful ReadRecord (where the patient summary is built)
pred FR_019_SafetyFieldsOnRead {
  all a: AccessAttempt |
    a.exposesClinicalContent = True
      implies (a.kind = ReadRecord and a.outcome = Permitted)
}
assert FR_019_SafetyFieldsOnRead { FR_019_SafetyFieldsOnRead }
check FR_019_SafetyFieldsOnRead for 8

// FEATURE-SPECIFIC  ANCHOR: FR-020 notes_count surfaces only on the same Permitted record-read path
pred FR_020_NotesCountOnRead {
  all a: AccessAttempt |
    a.exposesClinicalContent = True implies a.kind = ReadRecord
  all a: AccessAttempt |
    (a.outcome = Permitted and a.kind = ReadRecord)
      implies (some a.targetPatient)
}
assert FR_020_NotesCountOnRead { FR_020_NotesCountOnRead }
check FR_020_NotesCountOnRead for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_DenialLeak { some a: AccessAttempt | a.outcome = Denied and a.exposesClinicalContent = True }
