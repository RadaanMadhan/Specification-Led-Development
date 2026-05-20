// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===
// Feature: 013-hipaa-clinical-records (folder identifier supplied as "C-L3")
// Encodes the authorisation matrix, ownership / care-team gating, audit invariants,
// note append-only invariant, and byte-equivalent forbidden envelope.

// ---------------------------------------------------------------------------
// Non-empty universe so universally quantified predicates do not pass
// vacuously under empty interpretations.
// ---------------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some Record
  some Operation
  some AuditEntry
  some IPAddress
  some CareTeamMembership
  some ClinicalNote
}

// ---------------------------------------------------------------------------
// Roles (spec FR-002): exactly clinician, patient, compliance_officer
// ---------------------------------------------------------------------------
abstract sig Role {}
one sig Clinician extends Role {}
one sig Patient extends Role {}
one sig ComplianceOfficer extends Role {}

// ---------------------------------------------------------------------------
// Endpoint operation kinds (contracts/http-api.md)
// ---------------------------------------------------------------------------
abstract sig OperationKind {}
one sig GetRecord extends OperationKind {}            // GET /records/{id}
one sig PostNote extends OperationKind {}             // POST /records/{id}/notes
one sig GetRecordAudit extends OperationKind {}       // GET /records/{id}/audit
one sig GetAccessLog extends OperationKind {}         // GET /access-log

// ---------------------------------------------------------------------------
// Outcomes / membership status
// ---------------------------------------------------------------------------
abstract sig Outcome {}
one sig Permitted extends Outcome {}
one sig Denied extends Outcome {}

abstract sig MembershipStatus {}
one sig MActive extends MembershipStatus {}
one sig MEnded extends MembershipStatus {}

// ---------------------------------------------------------------------------
// Domain entities (data-model.md)
// ---------------------------------------------------------------------------
sig Record {}
sig IPAddress {}

sig User {
  role: one Role,
  assignedRecord: lone Record    // present iff role = Patient (FR-003)
}

sig CareTeamMembership {
  ctmClinician: one User,
  ctmRecord: one Record,
  ctmStatus: one MembershipStatus
}

sig ClinicalNote {
  noteRecord: one Record,
  noteAuthor: one User,
  noteAuthorRoleSnap: one Role
}

sig Operation {
  opActor: one User,
  opKind: one OperationKind,
  opTarget: lone Record,         // absent for GetAccessLog
  opOutcome: one Outcome,
  opIp: one IPAddress,
  opNote: lone ClinicalNote      // set iff PostNote && Permitted
}

sig AuditEntry {
  aeOp: one Operation,
  aeRecord: lone Record,
  aeAccessor: one User,
  aeRoleSnap: one Role,
  aeOpKind: one OperationKind,
  aeOutcome: one Outcome,
  aeIp: one IPAddress,
  aeNoteRef: lone ClinicalNote
}

// ---------------------------------------------------------------------------
// Permission matrix as a singleton-sig field (Role x OperationKind)
// Reflects contracts/http-api.md permission matrix (unconditional allow cells).
// Conditional rules (care-team / ownership) are layered in F_PermittedRequiresAuthorization.
// ---------------------------------------------------------------------------
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Clinician         -> GetRecord) +
    (Clinician         -> PostNote) +
    (Clinician         -> GetRecordAudit) +
    (Patient           -> GetRecord) +
    (Patient           -> GetRecordAudit) +
    (ComplianceOfficer -> GetRecordAudit) +
    (ComplianceOfficer -> GetAccessLog)
}

// ---------------------------------------------------------------------------
// Domain-shape facts
// ---------------------------------------------------------------------------

// FR-003: a patient has exactly one assigned record; non-patients have none.
fact F_PatientHasAssignedRecord {
  all u: User | u.role = Patient iff some u.assignedRecord
}

// data-model.md: clinical_notes.author_role = 'clinician' CHECK constraint.
fact F_NoteAuthorIsClinician {
  all n: ClinicalNote | n.noteAuthor.role = Clinician
  all n: ClinicalNote | n.noteAuthorRoleSnap = Clinician
}

// FR-013 / data-model.md operation-target / note-presence CHECK constraints.
fact F_OperationTargetRules {
  all op: Operation | op.opKind = GetAccessLog implies no op.opTarget
  all op: Operation | op.opKind in (GetRecord + PostNote + GetRecordAudit) implies some op.opTarget
  // opNote present iff PostNote+Permitted
  all op: Operation | some op.opNote iff (op.opKind = PostNote and op.opOutcome = Permitted)
  // A created note's record/author match the operation's target/actor.
  all op: Operation | some op.opNote implies
    (op.opNote.noteRecord = op.opTarget and op.opNote.noteAuthor = op.opActor)
}

// FR-004..FR-007: permitted outcome requires role allowance AND (where applicable)
// the conditional access predicate (care team membership / own assigned record).
fact F_PermittedRequiresAuthorization { /* MUTATED — body cleared by validator */ }

// FR-013: each operation produces exactly one audit entry; no duplicates.
fact F_AuditPerOperation {
  all op: Operation | one ae: AuditEntry | ae.aeOp = op
  all disj a1, a2: AuditEntry | a1.aeOp != a2.aeOp
}

// FR-014: audit-entry snapshot fields match the operation they record.
fact F_AuditAttributionCorrect {
  all ae: AuditEntry |
    ae.aeAccessor  = ae.aeOp.opActor and
    ae.aeRoleSnap  = ae.aeOp.opActor.role and
    ae.aeOpKind    = ae.aeOp.opKind and
    ae.aeOutcome   = ae.aeOp.opOutcome and
    ae.aeIp        = ae.aeOp.opIp and
    ae.aeRecord    = ae.aeOp.opTarget and
    ae.aeNoteRef   = ae.aeOp.opNote
}

// FR-012: every clinical note traces back to exactly one creating operation.
fact F_NotesUniquelyCreated {
  all n: ClinicalNote | one op: Operation | op.opNote = n
}

// ---------------------------------------------------------------------------
// Catalogue patterns
// ---------------------------------------------------------------------------

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004..FR-007
pred LeastPrivilege {
  some Operation
  all op: Operation |
    op.opOutcome = Permitted implies (op.opActor.role -> op.opKind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every cell that the spec marks deny must NOT be in Allowed,
  // and every cell that is marked allow must be in Allowed.
  (Clinician         -> GetRecord)        in PermMatrix.Allowed
  (Clinician         -> PostNote)         in PermMatrix.Allowed
  (Clinician         -> GetRecordAudit)   in PermMatrix.Allowed
  (Clinician         -> GetAccessLog) not in PermMatrix.Allowed
  (Patient           -> GetRecord)        in PermMatrix.Allowed
  (Patient           -> PostNote)     not in PermMatrix.Allowed
  (Patient           -> GetRecordAudit)   in PermMatrix.Allowed
  (Patient           -> GetAccessLog) not in PermMatrix.Allowed
  (ComplianceOfficer -> GetRecord)    not in PermMatrix.Allowed
  (ComplianceOfficer -> PostNote)     not in PermMatrix.Allowed
  (ComplianceOfficer -> GetRecordAudit)   in PermMatrix.Allowed
  (ComplianceOfficer -> GetAccessLog)     in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation | one op.opActor   // every op resolves to a single authenticated principal
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md audit_entries
pred AuditCompleteness {
  some Operation
  all op: Operation | (one ae: AuditEntry | ae.aeOp = op)
  all disj a1, a2: AuditEntry | a1.aeOp != a2.aeOp
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012, FR-015
pred AppendOnly {
  some ClinicalNote
  // Notes can't be "rewritten" by another operation — each note has exactly one creator.
  all n: ClinicalNote | (one op: Operation | op.opNote = n)
  // Audit entries can't be duplicated/mutated across operations.
  all disj a1, a2: AuditEntry | a1.aeOp != a2.aeOp
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md audit_entries snapshot fields
pred AttributionCorrectness {
  some AuditEntry
  all ae: AuditEntry |
    ae.aeAccessor = ae.aeOp.opActor and
    ae.aeRoleSnap = ae.aeOp.opActor.role and
    ae.aeOpKind   = ae.aeOp.opKind and
    ae.aeOutcome  = ae.aeOp.opOutcome and
    ae.aeRecord   = ae.aeOp.opTarget
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-003; data-model.md users.assigned_record_id CHECK
pred OwnershipExclusivity {
  some User
  all u: User | u.role = Patient    implies one u.assignedRecord
  all u: User | u.role != Patient   implies no  u.assignedRecord
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004, FR-006
pred OwnershipBasedAccess {
  some Operation
  // Clinician permitted access requires an active care-team-membership row.
  all op: Operation |
    (op.opOutcome = Permitted and op.opActor.role = Clinician and
     op.opKind in (GetRecord + PostNote + GetRecordAudit))
    implies (some m: CareTeamMembership |
              m.ctmClinician = op.opActor and
              m.ctmRecord    = op.opTarget and
              m.ctmStatus    = MActive)
  // Patient permitted access only on their assigned record.
  all op: Operation |
    (op.opOutcome = Permitted and op.opActor.role = Patient and
     op.opKind in (GetRecord + GetRecordAudit))
    implies op.opTarget = op.opActor.assignedRecord
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008; contracts/http-api.md byte-equivalent envelope
pred NoInformationLeakage {
  some Operation
  // Any caller whose (role, kind) is not in the unconditional allow set
  // can only ever receive the canonical Denied outcome — regardless of
  // whether the target record exists.
  all op: Operation |
    ((op.opActor.role -> op.opKind) not in PermMatrix.Allowed)
      implies op.opOutcome = Denied
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-010, FR-016
pred ValidationBeforeMutation {
  some Operation
  // A denied operation produces no clinical-note side effect.
  all op: Operation | op.opOutcome = Denied implies no op.opNote
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// ---------------------------------------------------------------------------
// Feature-specific predicates (one per FR-NNN)
// ---------------------------------------------------------------------------

// FEATURE-SPECIFIC  ANCHOR: FR-001 every Operation has an authenticated actor
pred FR_001_AuthRequired {
  some Operation
  all op: Operation | one op.opActor and one op.opActor.role
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 single role per user
pred FR_002_OneRolePerUser {
  some User
  all u: User | one u.role
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 patients have an assigned_record_id; non-patients do not
pred FR_003_PatientAssignedRecord {
  some User
  all u: User | u.role = Patient    implies one u.assignedRecord
  all u: User | u.role != Patient   implies no  u.assignedRecord
}
assert FR_003_PatientAssignedRecord { FR_003_PatientAssignedRecord }
check FR_003_PatientAssignedRecord for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 clinician access requires active care-team membership
pred FR_004_ClinicianCareTeamRequired {
  some Operation
  all op: Operation |
    (op.opOutcome = Permitted and op.opActor.role = Clinician and
     op.opKind in (GetRecord + PostNote + GetRecordAudit))
    implies (some m: CareTeamMembership |
              m.ctmClinician = op.opActor and
              m.ctmRecord    = op.opTarget and
              m.ctmStatus    = MActive)
}
assert FR_004_ClinicianCareTeamRequired { FR_004_ClinicianCareTeamRequired }
check FR_004_ClinicianCareTeamRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 clinician may NOT call GET /access-log
pred FR_005_AccessLogNotForClinician {
  some Operation
  all op: Operation |
    (op.opOutcome = Permitted and op.opKind = GetAccessLog)
      implies op.opActor.role = ComplianceOfficer
}
assert FR_005_AccessLogNotForClinician { FR_005_AccessLogNotForClinician }
check FR_005_AccessLogNotForClinician for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 patient access only on own assigned record; no PostNote; no AccessLog
pred FR_006_PatientOwnRecordOnly {
  some Operation
  all op: Operation |
    (op.opOutcome = Permitted and op.opActor.role = Patient)
      implies (op.opKind in (GetRecord + GetRecordAudit) and
               op.opTarget = op.opActor.assignedRecord)
}
assert FR_006_PatientOwnRecordOnly { FR_006_PatientOwnRecordOnly }
check FR_006_PatientOwnRecordOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 compliance MAY NOT read clinical content nor write
pred FR_007_ComplianceNoRecordRead {
  some Operation
  all op: Operation |
    (op.opOutcome = Permitted and op.opActor.role = ComplianceOfficer)
      implies op.opKind in (GetRecordAudit + GetAccessLog)
}
assert FR_007_ComplianceNoRecordRead { FR_007_ComplianceNoRecordRead }
check FR_007_ComplianceNoRecordRead for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 byte-equivalent forbidden envelope
pred FR_008_ByteEquivalentForbidden {
  some Operation
  // Any operation that lacks an unconditional role-allow (or, for clinician/patient
  // ops, lacks the conditional predicate) MUST yield Denied — uniformly, regardless
  // of whether the target record exists.
  all op: Operation |
    ((op.opActor.role -> op.opKind) not in PermMatrix.Allowed)
      implies op.opOutcome = Denied
}
assert FR_008_ByteEquivalentForbidden { FR_008_ByteEquivalentForbidden }
check FR_008_ByteEquivalentForbidden for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 a permitted note is persisted with snapshot fields linked to the op
pred FR_011_NoteSnapshot {
  some ClinicalNote
  all n: ClinicalNote | n.noteAuthor.role = Clinician
  all n: ClinicalNote | n.noteAuthorRoleSnap = Clinician
  all op: Operation | some op.opNote implies
    (op.opNote.noteRecord = op.opTarget and op.opNote.noteAuthor = op.opActor)
}
assert FR_011_NoteSnapshot { FR_011_NoteSnapshot }
check FR_011_NoteSnapshot for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 notes are append-only — no note shared across ops
pred FR_012_NotesAppendOnly {
  some ClinicalNote
  all n: ClinicalNote | (one op: Operation | op.opNote = n)
}
assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 exactly one audit entry per operation, no duplicates, no orphans
pred FR_013_AuditPerOp {
  some Operation
  all op: Operation | (one ae: AuditEntry | ae.aeOp = op)
  all ae: AuditEntry | one ae.aeOp
  all disj a1, a2: AuditEntry | a1.aeOp != a2.aeOp
}
assert FR_013_AuditPerOp { FR_013_AuditPerOp }
check FR_013_AuditPerOp for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 audit entries carry every required snapshot field, matching the op
pred FR_014_AuditFieldsComplete {
  some AuditEntry
  all ae: AuditEntry |
    one ae.aeAccessor and
    one ae.aeRoleSnap and
    one ae.aeOpKind and
    one ae.aeOutcome and
    one ae.aeIp and
    ae.aeRoleSnap = ae.aeOp.opActor.role and
    ae.aeOpKind   = ae.aeOp.opKind and
    ae.aeOutcome  = ae.aeOp.opOutcome
}
assert FR_014_AuditFieldsComplete { FR_014_AuditFieldsComplete }
check FR_014_AuditFieldsComplete for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 audit entries are immutable — no two AEs reference the same op
pred FR_015_AuditImmutable {
  some AuditEntry
  all disj a1, a2: AuditEntry | a1.aeOp != a2.aeOp
}
assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 GET /access-log is compliance-officer-only
pred FR_018_AccessLogComplianceOnly {
  some Operation
  all op: Operation |
    (op.opKind = GetAccessLog and op.opOutcome = Permitted)
      implies op.opActor.role = ComplianceOfficer
}
assert FR_018_AccessLogComplianceOnly { FR_018_AccessLogComplianceOnly }
check FR_018_AccessLogComplianceOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-019 compliance responses never carry clinical content;
// structurally: a compliance caller can never successfully read clinical content endpoints.
pred FR_019_ComplianceContentBlind {
  some Operation
  no op: Operation |
    op.opActor.role = ComplianceOfficer and
    op.opKind in (GetRecord + PostNote) and
    op.opOutcome = Permitted
}
assert FR_019_ComplianceContentBlind { FR_019_ComplianceContentBlind }
check FR_019_ComplianceContentBlind for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_PermittedWithoutAuthorization { some op: Operation | op.opOutcome = Permitted and (op.opActor.role -> op.opKind) not in PermMatrix.Allowed }
