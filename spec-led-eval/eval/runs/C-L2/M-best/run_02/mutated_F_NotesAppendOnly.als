// === feature_model.als — Alloy model for Hospital Clinical Record Access ===
// Feature: 012-hospital-clinical-records (C-L2)
// Encodes structural invariants from spec.md, data-model.md, contracts/http-api.md.

// ---------------------------------------------------------------------------
// Non-empty universe: ensure every dynamic sig has at least one atom so that
// universally-quantified assertions are not vacuously satisfied under for 5.
// ---------------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some AccessAttempt
  some AuditEntry
  some ClinicalNote
  some NoteAction
  some AuditAction
  some AdminResponse
}

// ---------------------------------------------------------------------------
// Bool helper (used by AdminResponse content-blindness flag)
// ---------------------------------------------------------------------------
abstract sig Bool {}
one sig TrueB, FalseB extends Bool {}

// ---------------------------------------------------------------------------
// Roles (FR-002, data-model.md UserRole enum)
// ---------------------------------------------------------------------------
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator extends Role {}

fun ClinicalRoles: set Role { Doctor + Nurse + Pharmacist + ClinicalAdmin }

// ---------------------------------------------------------------------------
// Operations exposed by the feature (contracts/http-api.md)
// ---------------------------------------------------------------------------
abstract sig OperationKind {}
one sig PostRecordsLookup, PostRecordsNotes, PostAuditSearch extends OperationKind {}

fun ClinicalOps: set OperationKind { PostRecordsLookup + PostRecordsNotes }

// ---------------------------------------------------------------------------
// Permission matrix (contracts/http-api.md authorisation tables)
// Role x OperationKind "allowed" cells, as a singleton-sig field.
// ---------------------------------------------------------------------------
one sig PermMatrix { Allowed: set Role -> OperationKind }

fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Doctor          -> PostRecordsLookup) + (Doctor          -> PostRecordsNotes)
    + (Nurse           -> PostRecordsLookup) + (Nurse           -> PostRecordsNotes)
    + (Pharmacist      -> PostRecordsLookup) + (Pharmacist      -> PostRecordsNotes)
    + (ClinicalAdmin   -> PostRecordsLookup) + (ClinicalAdmin   -> PostRecordsNotes)
    + (HospitalAdministrator -> PostAuditSearch)
}

// ---------------------------------------------------------------------------
// Outcomes (data-model.md AccessOutcome enum)
// ---------------------------------------------------------------------------
abstract sig Outcome {}
one sig Permitted, Denied, NotFoundOrDenied extends Outcome {}

// ---------------------------------------------------------------------------
// Membership status (data-model.md MembershipStatus enum)
// ---------------------------------------------------------------------------
abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

// ---------------------------------------------------------------------------
// Core entities
// ---------------------------------------------------------------------------
sig User { role: one Role }
sig Patient {}

sig CareTeamMembership {
  clinician: one User,
  patient:   one Patient,
  status:    one MembershipStatus
}

// An authenticated access attempt that reaches the service layer.
// Unauthenticated requests are rejected at the boundary (FR-001) and not modelled.
sig AccessAttempt {
  caller:  one User,
  patient: lone Patient,       // lone: nonexistent-patient case
  kind:    one OperationKind,
  outcome: one Outcome
}

// Append-only clinical note (FR-009, FR-010, FR-011)
sig ClinicalNote {
  notePatient:        one Patient,
  author:             one User,
  authorRoleSnapshot: one Role,
  createdBy:          one AccessAttempt
}

// Immutable audit entry (FR-012, FR-013, FR-014)
sig AuditEntry {
  attempt:         one AccessAttempt,
  recordedUser:    one User,
  recordedRole:    one Role,
  recordedKind:    one OperationKind,
  recordedOutcome: one Outcome,
  resultNote:      lone ClinicalNote
}

// Administrator response — has it leaked clinical content? (FR-018)
sig AdminResponse {
  responseFor:             one AccessAttempt,
  containsClinicalContent: one Bool
}

// ---------------------------------------------------------------------------
// Append-only operation log (lets us mutation-test FR-011 / FR-014)
// ---------------------------------------------------------------------------
abstract sig EntityOp {}
one sig CreateOp, ModifyOp, DeleteOp extends EntityOp {}

sig NoteAction  { targetNote:  one ClinicalNote, noteOp:  one EntityOp }
sig AuditAction { targetEntry: one AuditEntry,   auditOp: one EntityOp }

// ---------------------------------------------------------------------------
// Named structural facts — each is mutation-testable.
// ---------------------------------------------------------------------------

// FR-004, FR-005, FR-017: only allowed (role, op) cells can yield Permitted.
fact F_LeastPrivilegeMatrix {
  all a: AccessAttempt |
    a.outcome = Permitted implies (a.caller.role -> a.kind) in PermMatrix.Allowed
}

// FR-004: clinical-endpoint Permitted ⇒ active care-team membership.
fact F_CareTeamGating {
  all a: AccessAttempt |
    (a.outcome = Permitted and a.kind in ClinicalOps) implies
      ( some a.patient
        and a.caller.role in ClinicalRoles
        and (some m: CareTeamMembership |
               m.clinician = a.caller
               and m.patient = a.patient
               and m.status = Active) )
}

// FR-005, FR-017: PostAuditSearch Permitted ⇒ caller is HospitalAdministrator.
fact F_AdminEndpointRoleOnly {
  all a: AccessAttempt |
    (a.outcome = Permitted and a.kind = PostAuditSearch)
      implies a.caller.role = HospitalAdministrator
}

// FR-005: HospitalAdministrator can never succeed on a clinical endpoint.
fact F_AdminNoClinicalAccess {
  all a: AccessAttempt |
    (a.caller.role = HospitalAdministrator and a.kind in ClinicalOps)
      implies a.outcome != Permitted
}

// FR-012: every authenticated clinical access has exactly one audit entry.
fact F_AuditCompleteness {
  all a: AccessAttempt |
    a.kind in ClinicalOps implies (one e: AuditEntry | e.attempt = a)
}

// FR-013: audit-entry snapshot fields agree with the attempt they record.
fact F_AuditAttributionCorrect {
  all e: AuditEntry |
    e.recordedUser    = e.attempt.caller
    and e.recordedRole    = e.attempt.caller.role
    and e.recordedKind    = e.attempt.kind
    and e.recordedOutcome = e.attempt.outcome
}

// FR-013: note_id present iff (access_type = add_note and outcome = Permitted).
fact F_AuditNoteIdPairing {
  all e: AuditEntry |
    (some e.resultNote)
      iff (e.recordedKind = PostRecordsNotes and e.recordedOutcome = Permitted)
}

// FR-011: clinical notes are append-only.
fact F_NotesAppendOnly { /* MUTATED — body cleared by validator */ }

// FR-014, FR-016: audit entries are append-only / immutable.
fact F_AuditAppendOnly {
  all aa: AuditAction | aa.auditOp = CreateOp
}

// FR-010 / data-model CHECK: author_role on a clinical note must be clinical.
fact F_NoteAuthorClinical {
  all n: ClinicalNote | n.authorRoleSnapshot in ClinicalRoles
}

// FR-010, FR-015: a note exists only as the product of a Permitted add_note attempt;
// its snapshot fields match the originating attempt.
fact F_NoteCreationLinkedToAttempt {
  all n: ClinicalNote |
    n.createdBy.kind        = PostRecordsNotes
    and n.createdBy.outcome     = Permitted
    and n.author               = n.createdBy.caller
    and n.notePatient          = n.createdBy.patient
    and n.authorRoleSnapshot   = n.author.role
}

// FR-015: every persisted note has a matching successful add_note audit entry.
fact F_NoteAuditAtomicity {
  all n: ClinicalNote |
    one e: AuditEntry | e.attempt = n.createdBy and e.resultNote = n
}

// FR-005, FR-018: administrator responses carry no clinical content.
fact F_AdminNoClinicalContent {
  all r: AdminResponse |
    r.responseFor.kind = PostAuditSearch implies r.containsClinicalContent = FalseB
}

// FR-006: failed clinical attempts produce no observable clinical side effects
// (no note persisted on denied / not-found outcomes).
fact F_NoNoteOnFailedAttempt {
  all n: ClinicalNote | n.createdBy.outcome = Permitted
}

// ===========================================================================
// PATTERN ASSERTIONS
// ===========================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-004, FR-005, FR-017
pred LeastPrivilege {
  some AccessAttempt
  all a: AccessAttempt |
    a.outcome = Permitted implies (a.caller.role -> a.kind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6 but exactly 5 Role, exactly 3 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication
pred AuthRequiredEverywhere {
  some AccessAttempt
  all a: AccessAttempt | one a.caller and one a.caller.role
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012; data-model.md audit_entries
pred AuditCompleteness {
  some AccessAttempt
  all a: AccessAttempt |
    a.kind in ClinicalOps implies (one e: AuditEntry | e.attempt = a)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011 (notes) and FR-014 (audit); data-model.md no UPDATE/DELETE
pred AppendOnly {
  some NoteAction
  some AuditAction
  (all na: NoteAction  | na.noteOp  = CreateOp)
  (all aa: AuditAction | aa.auditOp = CreateOp)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md audit-entry snapshot fields
pred AttributionCorrectness {
  some AuditEntry
  all e: AuditEntry |
    e.recordedUser    = e.attempt.caller
    and e.recordedRole    = e.attempt.caller.role
    and e.recordedKind    = e.attempt.kind
    and e.recordedOutcome = e.attempt.outcome
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md care_team_memberships
pred OwnershipBasedAccess {
  some AccessAttempt
  all a: AccessAttempt |
    (a.outcome = Permitted and a.kind in ClinicalOps) implies
      ( some a.patient
        and (some m: CareTeamMembership |
               m.clinician = a.caller
               and m.patient = a.patient
               and m.status = Active) )
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-005, FR-006, FR-018
pred NoInformationLeakage {
  some AdminResponse
  all r: AdminResponse | r.containsClinicalContent = FalseB
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-009; data-model.md CHECK constraints
pred ValidationBeforeMutation {
  // failed attempts never produce a clinical note
  all n: ClinicalNote | n.createdBy.outcome = Permitted
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md clinical_notes.author_user_id (single author per note)
pred OwnershipExclusivity {
  all n: ClinicalNote | one n.author and one n.notePatient
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// ===========================================================================
// FEATURE-SPECIFIC FR ASSERTIONS
// ===========================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 Authentication required
pred FR_001_AuthRequired {
  all a: AccessAttempt | one a.caller
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 Role catalogue (exactly five roles, one per user)
pred FR_002_RoleCatalogue {
  Role = Doctor + Nurse + Pharmacist + ClinicalAdmin + HospitalAdministrator
  all u: User | one u.role
}
assert FR_002_RoleCatalogue { FR_002_RoleCatalogue }
check FR_002_RoleCatalogue for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 Care-team membership gating
pred FR_004_CareTeamGating {
  some AccessAttempt
  all a: AccessAttempt |
    (a.outcome = Permitted and a.kind in ClinicalOps) implies
      ( a.caller.role in ClinicalRoles
        and some a.patient
        and (some m: CareTeamMembership |
               m.clinician = a.caller
               and m.patient = a.patient
               and m.status = Active) )
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 Admin cannot read clinical content
pred FR_005_AdminNoClinicalAccess {
  all a: AccessAttempt |
    (a.caller.role = HospitalAdministrator and a.kind in ClinicalOps)
      implies a.outcome != Permitted
}
assert FR_005_AdminNoClinicalAccess { FR_005_AdminNoClinicalAccess }
check FR_005_AdminNoClinicalAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 Byte-equivalent denial — no clinical content escapes failed attempts
pred FR_006_NoLeakOnFailedAttempt {
  all n: ClinicalNote | n.createdBy.outcome = Permitted
}
assert FR_006_NoLeakOnFailedAttempt { FR_006_NoLeakOnFailedAttempt }
check FR_006_NoLeakOnFailedAttempt for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 Note author/patient/role match the originating attempt
pred FR_010_NoteFieldsSnapshot {
  some ClinicalNote
  all n: ClinicalNote |
    n.createdBy.kind        = PostRecordsNotes
    and n.createdBy.outcome     = Permitted
    and n.author               = n.createdBy.caller
    and n.notePatient          = n.createdBy.patient
    and n.authorRoleSnapshot   = n.author.role
    and n.authorRoleSnapshot   in ClinicalRoles
}
assert FR_010_NoteFieldsSnapshot { FR_010_NoteFieldsSnapshot }
check FR_010_NoteFieldsSnapshot for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 Clinical notes append-only
pred FR_011_NotesAppendOnly {
  some NoteAction
  all na: NoteAction | na.noteOp = CreateOp
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 Exactly one audit entry per clinical access attempt
pred FR_012_OneAuditPerAttempt {
  some AccessAttempt
  all a: AccessAttempt |
    a.kind in ClinicalOps implies (one e: AuditEntry | e.attempt = a)
}
assert FR_012_OneAuditPerAttempt { FR_012_OneAuditPerAttempt }
check FR_012_OneAuditPerAttempt for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 Audit-entry attribution matches the attempt
pred FR_013_AuditAttribution {
  some AuditEntry
  all e: AuditEntry |
    e.recordedUser    = e.attempt.caller
    and e.recordedRole    = e.attempt.caller.role
    and e.recordedKind    = e.attempt.kind
    and e.recordedOutcome = e.attempt.outcome
}
assert FR_013_AuditAttribution { FR_013_AuditAttribution }
check FR_013_AuditAttribution for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 note_id presence pairing
pred FR_013_NoteIdPairing {
  all e: AuditEntry |
    (some e.resultNote)
      iff (e.recordedKind = PostRecordsNotes and e.recordedOutcome = Permitted)
}
assert FR_013_NoteIdPairing { FR_013_NoteIdPairing }
check FR_013_NoteIdPairing for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014, FR-016 Audit entries immutable / retained
pred FR_014_AuditImmutable {
  some AuditAction
  all aa: AuditAction | aa.auditOp = CreateOp
}
assert FR_014_AuditImmutable { FR_014_AuditImmutable }
check FR_014_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 Note + audit persisted atomically
pred FR_015_AtomicNoteAndAudit {
  some ClinicalNote
  all n: ClinicalNote |
    one e: AuditEntry | e.attempt = n.createdBy and e.resultNote = n
}
assert FR_015_AtomicNoteAndAudit { FR_015_AtomicNoteAndAudit }
check FR_015_AtomicNoteAndAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 Admin endpoint is administrator-only
pred FR_017_AdminEndpointRoleOnly {
  all a: AccessAttempt |
    (a.outcome = Permitted and a.kind = PostAuditSearch)
      implies a.caller.role = HospitalAdministrator
}
assert FR_017_AdminEndpointRoleOnly { FR_017_AdminEndpointRoleOnly }
check FR_017_AdminEndpointRoleOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018 Admin response contains no clinical content
pred FR_018_AdminNoClinicalContent {
  some AdminResponse
  all r: AdminResponse |
    r.responseFor.kind = PostAuditSearch implies r.containsClinicalContent = FalseB
}
assert FR_018_AdminNoClinicalContent { FR_018_AdminNoClinicalContent }
check FR_018_AdminNoClinicalContent for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_NotesAppendOnly { some na: NoteAction | na.noteOp = ModifyOp }
