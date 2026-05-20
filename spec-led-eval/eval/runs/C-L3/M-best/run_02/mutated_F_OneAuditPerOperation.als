// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access (013-hipaa-clinical-records / C-L3) ===

// ---------------------------------------------------------------
// Roles
// ---------------------------------------------------------------
abstract sig Role {}
one sig Clinician, Patient, ComplianceOfficer extends Role {}

// ---------------------------------------------------------------
// Operation kinds (the four feature endpoints)
//   ReadRecord       = GET /records/{id}
//   AppendNote       = POST /records/{id}/notes
//   ListRecordAudit  = GET /records/{id}/audit
//   ListAccessLog    = GET /access-log
// ---------------------------------------------------------------
abstract sig OperationKind {}
one sig ReadRecord, AppendNote, ListRecordAudit, ListAccessLog extends OperationKind {}

// ---------------------------------------------------------------
// Outcomes
// ---------------------------------------------------------------
abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

// ---------------------------------------------------------------
// Domain entities (data-model.md)
// ---------------------------------------------------------------
sig Record {}

sig User {
  role: one Role,
  assignedRecord: lone Record
}

// Care-team membership: many-to-many clinician×record relation,
// modelled as a field on a singleton for cleanness.
one sig CareTeam {
  members: set User -> Record
}

sig ClinicalNote {
  noteRecord: one Record,
  author: one User
}

// One attempted access (request).
sig Operation {
  actor: one User,
  target: lone Record,           // lone: ListAccessLog has no target
  opKind: one OperationKind,
  outcome: one Outcome,
  createdNote: lone ClinicalNote  // populated iff permitted append
}

// Immutable audit-log entry tied to exactly one Operation.
sig AuditEntry {
  op: one Operation,
  accessor: one User,
  auditRecord: lone Record,
  auditOpKind: one OperationKind,
  auditOutcome: one Outcome
}

// ---------------------------------------------------------------
// Permission matrix as a field on a singleton sig.
// Cells listed below are the *may-allow* cells from contracts/http-api.md.
// Conditional refinements (care-team / patient-own / access-log target)
// are layered on top in IsPermitted.
// ---------------------------------------------------------------
one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// ---------------------------------------------------------------
// Non-empty universe so every `all`-quantified assertion bites.
// ---------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some Record
  some ClinicalNote
  some Operation
  some AuditEntry
}

// ---------------------------------------------------------------
// Permission matrix — closed-world enumeration (contracts/http-api.md table).
// ---------------------------------------------------------------
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Clinician         -> ReadRecord)
    + (Clinician         -> AppendNote)
    + (Clinician         -> ListRecordAudit)
    + (Patient           -> ReadRecord)
    + (Patient           -> ListRecordAudit)
    + (ComplianceOfficer -> ListRecordAudit)
    + (ComplianceOfficer -> ListAccessLog)
}

// ---------------------------------------------------------------
// FR-003: patient ⇔ assignedRecord pairing.
// ---------------------------------------------------------------
fact F_PatientAssignedRecord {
  all u: User | (u.role = Patient) iff (some u.assignedRecord)
}

// ---------------------------------------------------------------
// FR-004 schema CHECK: only clinicians can be care-team members.
// ---------------------------------------------------------------
fact F_CareTeamClinicians {
  all u: User, r: Record |
    u -> r in CareTeam.members implies u.role = Clinician
}

// ---------------------------------------------------------------
// data-model.md CHECK(author_role = 'clinician') for clinical_notes.
// ---------------------------------------------------------------
fact F_NoteAuthorClinician {
  all n: ClinicalNote | n.author.role = Clinician
}

// ---------------------------------------------------------------
// FR-004 / FR-011: a note's author must be on the record's care team.
// ---------------------------------------------------------------
fact F_NoteAuthorInCareTeam {
  all n: ClinicalNote | n.author -> n.noteRecord in CareTeam.members
}

// ---------------------------------------------------------------
// data-model.md: record_id is NULL exactly for ListAccessLog events.
// ---------------------------------------------------------------
fact F_OperationTargetByKind {
  all o: Operation | (o.opKind = ListAccessLog) iff (no o.target)
}

// ---------------------------------------------------------------
// FR-011 / FR-012: notes ↔ permitted-append operations are bijective.
// ---------------------------------------------------------------
fact F_NoteOpLink {
  all o: Operation |
    (o.opKind = AppendNote and o.outcome = Permitted) iff (some o.createdNote)
  all o: Operation | some o.createdNote implies
    (o.createdNote.author = o.actor and o.createdNote.noteRecord = o.target)
  all n: ClinicalNote | (one o: Operation | o.createdNote = n)
}

// ---------------------------------------------------------------
// FR-013: exactly one audit entry per operation.
// ---------------------------------------------------------------
fact F_OneAuditPerOperation { /* MUTATED — body cleared by validator */ }

// ---------------------------------------------------------------
// FR-014: audit-entry fields faithfully snapshot the operation.
// ---------------------------------------------------------------
fact F_AuditAttribution {
  all a: AuditEntry |
    a.accessor     = a.op.actor   and
    a.auditRecord  = a.op.target  and
    a.auditOpKind  = a.op.opKind  and
    a.auditOutcome = a.op.outcome
}

// ---------------------------------------------------------------
// Outcome rule: an op is Permitted iff the matrix cell allows AND the
// conditional access predicate (care-team / patient-own / list-target) holds.
// ---------------------------------------------------------------
fact F_PermissionRule {
  all o: Operation |
    o.outcome = Permitted iff IsPermitted[o.actor, o.target, o.opKind]
}

// Helper predicate: matrix membership plus conditional refinements.
pred IsPermitted[u: User, r: set Record, k: OperationKind] {
  u.role -> k in PermMatrix.Allowed
  (u.role = Clinician and (k = ReadRecord or k = AppendNote or k = ListRecordAudit))
    implies (some r and u -> r in CareTeam.members)
  (u.role = Patient and (k = ReadRecord or k = ListRecordAudit))
    implies (some r and u.assignedRecord = r)
  (u.role = ComplianceOfficer and k = ListRecordAudit) implies (some r)
  (k = ListAccessLog) implies (no r)
}

// ===============================================================
// Pattern assertions
// ===============================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  some Operation
  all o: Operation | one o.actor
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004..FR-007
pred LeastPrivilege {
  some Operation
  all o: Operation |
    o.outcome = Permitted implies
      ((o.actor.role -> o.opKind) in PermMatrix.Allowed and
       IsPermitted[o.actor, o.target, o.opKind])
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every expected allow-cell is present...
  (Clinician         -> ReadRecord)      in PermMatrix.Allowed
  (Clinician         -> AppendNote)      in PermMatrix.Allowed
  (Clinician         -> ListRecordAudit) in PermMatrix.Allowed
  (Patient           -> ReadRecord)      in PermMatrix.Allowed
  (Patient           -> ListRecordAudit) in PermMatrix.Allowed
  (ComplianceOfficer -> ListRecordAudit) in PermMatrix.Allowed
  (ComplianceOfficer -> ListAccessLog)   in PermMatrix.Allowed
  // ...and every expected deny-cell is absent.
  (Patient           -> AppendNote)      not in PermMatrix.Allowed
  (Patient           -> ListAccessLog)   not in PermMatrix.Allowed
  (ComplianceOfficer -> ReadRecord)      not in PermMatrix.Allowed
  (ComplianceOfficer -> AppendNote)      not in PermMatrix.Allowed
  (Clinician         -> ListAccessLog)   not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md audit_entries
pred AuditCompleteness {
  some Operation
  all o: Operation | (one a: AuditEntry | a.op = o)
  all disj a1, a2: AuditEntry | a1.op != a2.op
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md audit-entry fields
pred AttributionCorrectness {
  some AuditEntry
  all a: AuditEntry |
    a.accessor     = a.op.actor   and
    a.auditRecord  = a.op.target  and
    a.auditOpKind  = a.op.opKind  and
    a.auditOutcome = a.op.outcome
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012, FR-015; data-model.md notes/audit append-only
pred AppendOnly {
  some ClinicalNote
  // Every note traces back to exactly one permitted-append operation.
  all n: ClinicalNote |
    (one o: Operation | o.createdNote = n and
                        o.opKind = AppendNote and
                        o.outcome = Permitted)
  // No two audit entries replay the same operation.
  all disj a1, a2: AuditEntry | a1.op != a2.op
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004 (care team), FR-006 (patient own record)
pred OwnershipBasedAccess {
  some Operation
  all o: Operation |
    (o.outcome = Permitted and o.actor.role = Clinician and
     (o.opKind = ReadRecord or o.opKind = AppendNote or o.opKind = ListRecordAudit))
    implies (o.actor -> o.target) in CareTeam.members
  all o: Operation |
    (o.outcome = Permitted and o.actor.role = Patient and
     (o.opKind = ReadRecord or o.opKind = ListRecordAudit))
    implies o.actor.assignedRecord = o.target
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008; SC-003
pred NoInformationLeakage {
  some Operation
  // Denied operations produce no clinical-note side effect.
  all o: Operation | o.outcome = Denied implies no o.createdNote
  // Denied operations are not actually permitted under the matrix+conditions
  // (so the byte-equivalent 403 envelope cannot mask a "true" permitted access).
  all o: Operation | o.outcome = Denied implies
    not IsPermitted[o.actor, o.target, o.opKind]
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// ===============================================================
// Feature-specific FR assertions
// ===============================================================

// FEATURE-SPECIFIC  ANCHOR: FR-002 — exactly one role per user
pred FR_002_OneRolePerUser {
  some User
  all u: User | one u.role
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 — patient ⇔ assigned_record_id pairing
pred FR_003_PatientAssignedRecord {
  some User
  all u: User | (u.role = Patient) iff (some u.assignedRecord)
}
assert FR_003_PatientAssignedRecord { FR_003_PatientAssignedRecord }
check FR_003_PatientAssignedRecord for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 — clinician read/append gated by care-team membership
pred FR_004_ClinicianCareTeamGating {
  some Operation
  all o: Operation |
    (o.outcome = Permitted and o.actor.role = Clinician and
     (o.opKind = ReadRecord or o.opKind = AppendNote))
    implies (o.actor -> o.target) in CareTeam.members
}
assert FR_004_ClinicianCareTeamGating { FR_004_ClinicianCareTeamGating }
check FR_004_ClinicianCareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 — clinician per-record audit requires care team; no access-log for clinicians
pred FR_005_ClinicianAuditAccess {
  some Operation
  all o: Operation |
    (o.outcome = Permitted and o.actor.role = Clinician and o.opKind = ListRecordAudit)
    implies (o.actor -> o.target) in CareTeam.members
  no o: Operation |
    o.actor.role = Clinician and o.opKind = ListAccessLog and o.outcome = Permitted
}
assert FR_005_ClinicianAuditAccess { FR_005_ClinicianAuditAccess }
check FR_005_ClinicianAuditAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 — patient may only access own record; no append; no access-log
pred FR_006_PatientSelfAccess {
  some Operation
  all o: Operation |
    (o.outcome = Permitted and o.actor.role = Patient and
     (o.opKind = ReadRecord or o.opKind = ListRecordAudit))
    implies o.actor.assignedRecord = o.target
  no o: Operation |
    o.actor.role = Patient and o.opKind = AppendNote and o.outcome = Permitted
  no o: Operation |
    o.actor.role = Patient and o.opKind = ListAccessLog and o.outcome = Permitted
}
assert FR_006_PatientSelfAccess { FR_006_PatientSelfAccess }
check FR_006_PatientSelfAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 — compliance officer cannot read clinical content nor append notes
pred FR_007_ComplianceContentForbidden {
  no o: Operation |
    o.actor.role = ComplianceOfficer and o.opKind = ReadRecord and o.outcome = Permitted
  no o: Operation |
    o.actor.role = ComplianceOfficer and o.opKind = AppendNote and o.outcome = Permitted
}
assert FR_007_ComplianceContentForbidden { FR_007_ComplianceContentForbidden }
check FR_007_ComplianceContentForbidden for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 — byte-equivalent unauthorised response: denied ⇒ no clinical side-effect
pred FR_008_ByteEquivalentDenied {
  some Operation
  all o: Operation | o.outcome = Denied implies no o.createdNote
}
assert FR_008_ByteEquivalentDenied { FR_008_ByteEquivalentDenied }
check FR_008_ByteEquivalentDenied for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010/FR-011 — note structural invariants (author/record snapshot)
pred FR_011_NoteFieldsSnapshot {
  some ClinicalNote
  all n: ClinicalNote |
    n.author.role = Clinician and
    (one o: Operation | o.createdNote = n and
                        o.actor = n.author and
                        o.target = n.noteRecord and
                        o.opKind = AppendNote and
                        o.outcome = Permitted)
}
assert FR_011_NoteFieldsSnapshot { FR_011_NoteFieldsSnapshot }
check FR_011_NoteFieldsSnapshot for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 — clinical notes append-only (each note ↔ one creating op)
pred FR_012_NotesAppendOnly {
  some ClinicalNote
  all n: ClinicalNote |
    (one o: Operation | o.createdNote = n and
                        o.opKind = AppendNote and
                        o.outcome = Permitted)
}
assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 — every operation produces exactly one audit entry
pred FR_013_OneAuditPerOperation {
  some Operation
  all o: Operation | (one a: AuditEntry | a.op = o)
  all disj a1, a2: AuditEntry | a1.op != a2.op
}
assert FR_013_OneAuditPerOperation { FR_013_OneAuditPerOperation }
check FR_013_OneAuditPerOperation for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 — audit-entry fields mirror the operation faithfully
pred FR_014_AuditFieldsCorrect {
  some AuditEntry
  all a: AuditEntry |
    a.accessor     = a.op.actor   and
    a.auditRecord  = a.op.target  and
    a.auditOpKind  = a.op.opKind  and
    a.auditOutcome = a.op.outcome
}
assert FR_014_AuditFieldsCorrect { FR_014_AuditFieldsCorrect }
check FR_014_AuditFieldsCorrect for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 — audit entries immutable: each audit row is uniquely linked
pred FR_015_AuditImmutable {
  some AuditEntry
  all disj a1, a2: AuditEntry | a1.op != a2.op
  all a: AuditEntry | one a.op
}
assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 — /access-log is compliance-officer-only
pred FR_018_AccessLogComplianceOnly {
  all o: Operation |
    (o.opKind = ListAccessLog and o.outcome = Permitted) implies
      o.actor.role = ComplianceOfficer
}
assert FR_018_AccessLogComplianceOnly { FR_018_AccessLogComplianceOnly }
check FR_018_AccessLogComplianceOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 — compliance content-blindness: no compliance officer authors or reads clinical content
pred FR_019_ComplianceContentBlindness {
  no n: ClinicalNote | n.author.role = ComplianceOfficer
  no o: Operation |
    o.actor.role = ComplianceOfficer and
    (o.opKind = ReadRecord or o.opKind = AppendNote) and
    o.outcome = Permitted
}
assert FR_019_ComplianceContentBlindness { FR_019_ComplianceContentBlindness }
check FR_019_ComplianceContentBlindness for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020 — record_id only in URL paths (target is a Record handle, not a User)
pred FR_020_RecordIdHandle {
  // Operation targets are Records, never anything else — encoded structurally
  // by the typed field `target: lone Record`. Restating it here as a checkable claim.
  all o: Operation | o.target in Record
}
assert FR_020_RecordIdHandle { FR_020_RecordIdHandle }
check FR_020_RecordIdHandle for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AuditCompletenessViolation { some o: Operation | no a: AuditEntry | a.op = o }
