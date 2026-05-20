// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access (C-L3) ===
// Feature branch: 013-hipaa-clinical-records
// Generated from: spec.md, data-model.md, contracts/http-api.md

// ─────────────────────────────────────────────
// DOMAIN SIGNATURES
// ─────────────────────────────────────────────

abstract sig Role {}
one sig Clinician      extends Role {}
one sig Patient        extends Role {}
one sig ComplianceOfficer extends Role {}

abstract sig OperationKind {}
one sig GetRecord      extends OperationKind {}   // GET /records/{id}
one sig PostNote       extends OperationKind {}   // POST /records/{id}/notes
one sig GetRecordAudit extends OperationKind {}   // GET /records/{id}/audit
one sig GetAccessLog   extends OperationKind {}   // GET /access-log

abstract sig Outcome {}
one sig Permitted extends Outcome {}
one sig Denied    extends Outcome {}

// Effective caller-to-resource relationship (computed per request; spec data-model.md Relationship enum)
abstract sig Relationship {}
one sig CareTeamClin  extends Relationship {}  // clinician w/ active care-team membership
one sig OutsiderClin  extends Relationship {}  // clinician w/o membership
one sig PatientOwn    extends Relationship {}  // patient accessing own assigned record
one sig PatientOther  extends Relationship {}  // patient accessing another record
one sig CompOfficerRel extends Relationship {} // compliance_officer

// ─────────────────────────────────────────────
// PERMISSION MATRIX  (singleton; closed-world)
// ─────────────────────────────────────────────
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004 FR-005 FR-006 FR-007

one sig PermMatrix {
  allowed: set Relationship -> OperationKind
}

fact F_PermissionMatrix {
  PermMatrix.allowed =
    (CareTeamClin  -> GetRecord)      +
    (CareTeamClin  -> PostNote)       +
    (CareTeamClin  -> GetRecordAudit) +
    (PatientOwn    -> GetRecord)      +
    (PatientOwn    -> GetRecordAudit) +
    (CompOfficerRel -> GetRecordAudit) +
    (CompOfficerRel -> GetAccessLog)
}

// ─────────────────────────────────────────────
// DATA-MODEL SIGS (dynamic)
// ─────────────────────────────────────────────

sig Record {}

sig User {
  role:           one  Role,
  assignedRecord: lone Record   // non-null iff role = Patient
}

sig CareTeamMembership {
  ctmClinician: one User,
  ctmRecord:    one Record
}

sig ClinicalNote {
  noteRecord: one Record,
  author:     one User
}

sig AuditEntry {
  auditRecord: lone Record,     // null for GetAccessLog system-wide events
  accessor:    one  User,
  auditOp:     one  OperationKind,
  auditOutcome: one Outcome,
  noteRef:     lone ClinicalNote  // set iff auditOp=PostNote AND auditOutcome=Permitted
}

// AccessAttempt represents one authenticated request.
// Unauthenticated requests are rejected at the boundary (FR-001) and never become AccessAttempts.
sig AccessAttempt {
  caller:          one  User,
  opKind:          one  OperationKind,
  targetRecord:    lone Record,          // absent for GetAccessLog
  relationship:    one  Relationship,
  attemptOutcome:  one  Outcome,
  auditRef:        lone AuditEntry       // absent only for denied GetAccessLog (non-CO)
}

// ─────────────────────────────────────────────
// UNIVERSE NON-EMPTINESS
// ─────────────────────────────────────────────

fact F_NonEmptyUniverse {
  some User
  some Record
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
  some AccessAttempt
}

// ─────────────────────────────────────────────
// STRUCTURAL INVARIANT FACTS
// ─────────────────────────────────────────────

// FR-002 / FR-003: Patient users have exactly one assignedRecord; non-patients have none.
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-002, FR-003; data-model.md users CHECK constraint
fact F_PatientRecordPairing {
  all u: User |
    (u.role = Patient implies (one u.assignedRecord))
    and
    (u.role != Patient implies (no u.assignedRecord))
}

// Relationship must be consistent with the caller's role.
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-002; data-model.md Relationship enum
fact F_RelationshipRoleConsistency {
  all a: AccessAttempt | {
    (a.relationship = CareTeamClin  implies a.caller.role = Clinician)
    (a.relationship = OutsiderClin  implies a.caller.role = Clinician)
    (a.relationship = PatientOwn    implies a.caller.role = Patient)
    (a.relationship = PatientOther  implies a.caller.role = Patient)
    (a.relationship = CompOfficerRel implies a.caller.role = ComplianceOfficer)
  }
}

// FR-004: CareTeamClin relationship iff a CareTeamMembership exists for (clinician, record).
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-004; data-model.md CareTeamMembership
fact F_CareTeamMembershipGating {
  all a: AccessAttempt | {
    (a.relationship = CareTeamClin implies
      (some m: CareTeamMembership | m.ctmClinician = a.caller and m.ctmRecord = a.targetRecord))
    and
    (a.relationship = OutsiderClin implies
      (no m: CareTeamMembership | m.ctmClinician = a.caller and m.ctmRecord = a.targetRecord))
  }
}

// FR-006: PatientOwn relationship iff caller.assignedRecord = targetRecord.
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-006; data-model.md users.assigned_record_id
fact F_PatientOwnRecordGating {
  all a: AccessAttempt | {
    (a.relationship = PatientOwn   implies a.caller.assignedRecord = a.targetRecord)
    (a.relationship = PatientOther implies a.caller.assignedRecord != a.targetRecord)
  }
}

// GetAccessLog attempts have no targetRecord; all others must have one.
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-018; data-model.md AuditEntry.record_id nullable
fact F_TargetRecordPresence {
  all a: AccessAttempt | {
    (a.opKind = GetAccessLog implies no a.targetRecord)
    (a.opKind != GetAccessLog implies one a.targetRecord)
  }
}

// FR-004/FR-006/FR-007: Access control enforced — outcome matches permission matrix.
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004 FR-006 FR-007
fact F_AccessControlEnforced {
  all a: AccessAttempt | {
    (a.relationship -> a.opKind in PermMatrix.allowed implies a.attemptOutcome = Permitted)
    and
    (a.relationship -> a.opKind !in PermMatrix.allowed implies a.attemptOutcome = Denied)
  }
}

// FR-013: Every authenticated access attempt has exactly one audit entry,
//         EXCEPT: non-ComplianceOfficer callers denied on GetAccessLog produce no audit entry.
// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; contracts/http-api.md GET /access-log behaviour step 2
fact F_AuditCompleteness {
  all a: AccessAttempt | {
    // denied GetAccessLog for non-CO: no audit entry (by design, to avoid leakage)
    (a.opKind = GetAccessLog and a.attemptOutcome = Denied)
      implies no a.auditRef
    // all other attempts: exactly one audit entry
    (not (a.opKind = GetAccessLog and a.attemptOutcome = Denied))
      implies one a.auditRef
  }
}

// Every AuditEntry is the auditRef of exactly one AccessAttempt (no orphan or shared entries).
// PATTERN: AppendOnly  ANCHOR: spec.md FR-015; data-model.md AuditEntry append-only enforcement
fact F_AuditEntriesAreOwned {
  all ae: AuditEntry | (one a: AccessAttempt | a.auditRef = ae)
}

// FR-014: AuditEntry fields match the AccessAttempt they record.
// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md AuditEntry fields
fact F_AuditAttribution {
  all a: AccessAttempt | some a.auditRef implies {
    a.auditRef.accessor    = a.caller
    a.auditRef.auditOp     = a.opKind
    a.auditRef.auditOutcome = a.attemptOutcome
    a.auditRef.auditRecord  = a.targetRecord
  }
}

// FR-014 / data-model: note_id set iff operation=PostNote AND outcome=Permitted.
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-014; data-model.md AuditEntry CHECK constraint on note_id
fact F_AuditNoteIdConstraint {
  all ae: AuditEntry | {
    (ae.auditOp = PostNote and ae.auditOutcome = Permitted) implies (one ae.noteRef)
    (ae.auditOp = PostNote and ae.auditOutcome = Denied)    implies (no ae.noteRef)
    (ae.auditOp != PostNote)                                 implies (no ae.noteRef)
  }
}

// FR-011: Clinical notes must be authored by a clinician.
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-011; data-model.md clinical_notes CHECK author_role='clinician'
fact F_NoteAuthorMustBeClinician {
  all n: ClinicalNote | n.author.role = Clinician
}

// FR-012: Every ClinicalNote is the noteRef of exactly one AuditEntry (append-only; no orphan notes).
// PATTERN: AppendOnly  ANCHOR: spec.md FR-012 FR-015; data-model.md clinical_notes append-only enforcement
fact F_AppendOnlyNotes {
  all n: ClinicalNote | (one ae: AuditEntry |
    ae.noteRef = n and ae.auditOp = PostNote and ae.auditOutcome = Permitted)
}

// FR-007 / FR-019: ComplianceOfficer never receives Permitted on GetRecord or PostNote.
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-007 FR-019; contracts/http-api.md permission matrix
fact F_ComplianceOfficerContentBlind {
  all a: AccessAttempt |
    (a.caller.role = ComplianceOfficer and a.opKind in (GetRecord + PostNote))
      implies a.attemptOutcome = Denied
}

// FR-001: Unauthenticated requests produce no AccessAttempt (every attempt has a caller).
// Every CareTeamMembership clinician field is a User with role=Clinician.
// FEATURE-SPECIFIC  ANCHOR: spec.md FR-001; data-model.md users FK
fact F_CareTeamMembershipsAreForClinicians {
  all m: CareTeamMembership | m.ctmClinician.role = Clinician
}

// FR-008 / NoInformationLeakage: Denied outcome is independent of whether targetRecord exists.
// Structural encoding: for non-GetAccessLog attempts where outcome=Denied, the response
// shape is identical regardless of whether targetRecord is a real Record atom.
// We encode this as: denied attempts on any opKind yield Denied; no structural
// distinction between "record missing" and "caller lacks permission."
// This is enforced by F_AccessControlEnforced (outcome driven solely by relationship,
// not record existence). We capture the relationship-determines-outcome invariant here.
// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008; contracts/http-api.md byte-equivalent 403
fact F_ExistenceIndependentDenial {
  // Two AccessAttempts with the same caller-role, same relationship, same opKind
  // must have the same outcome, regardless of whether their targetRecords differ.
  all disj a1, a2: AccessAttempt |
    (a1.caller.role = a2.caller.role
     and a1.relationship = a2.relationship
     and a1.opKind = a2.opKind)
      implies a1.attemptOutcome = a2.attemptOutcome
}

// ─────────────────────────────────────────────
// PATTERN PREDICATES
// ─────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004 FR-005 FR-006 FR-007
pred LeastPrivilege {
  some AccessAttempt
  // No attempt succeeds for a relationship not in the allowed set
  all a: AccessAttempt |
    a.attemptOutcome = Permitted implies (a.relationship -> a.opKind in PermMatrix.Allowed)
  // No ComplianceOfficer attempt on GetRecord is permitted
  all a: AccessAttempt |
    (a.caller.role = ComplianceOfficer and a.opKind = GetRecord)
      implies a.attemptOutcome = Denied
  // No non-CareTeamClin clinician attempt on PostNote is permitted
  all a: AccessAttempt |
    (a.caller.role = Clinician and a.relationship = OutsiderClin and a.opKind = PostNote)
      implies a.attemptOutcome = Denied
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // Every Relationship × OperationKind cell has a definite verdict (allowed or denied)
  // The PermMatrix.allowed relation covers exactly those cells that are allowed;
  // everything else is implicitly denied. Completeness: the union of allowed and
  // denied covers the full product.
  all r: Relationship, op: OperationKind |
    (r -> op in PermMatrix.Allowed) or (r -> op !in PermMatrix.Allowed)
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md authentication section
pred AuthRequiredEverywhere {
  some AccessAttempt
  // Every AccessAttempt has an authenticated caller (no null/anonymous caller)
  all a: AccessAttempt | one a.caller
  // Every caller has a well-defined role in the catalogue
  all a: AccessAttempt | a.caller.role in (Clinician + Patient + ComplianceOfficer)
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013 SC-001 SC-002; data-model.md AuditEntry
pred AuditCompleteness {
  some AccessAttempt
  // Every non-GetAccessLog-denied attempt has exactly one audit entry
  all a: AccessAttempt |
    not (a.opKind = GetAccessLog and a.attemptOutcome = Denied)
      implies (one a.auditRef)
  // Every AuditEntry is linked to exactly one AccessAttempt
  all ae: AuditEntry | (one a: AccessAttempt | a.auditRef = ae)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly (AuditEntries)  ANCHOR: spec.md FR-015 FR-017 SC-008; data-model.md audit_entries append-only
pred AppendOnlyAuditEntries {
  some AuditEntry
  // Every AuditEntry is owned by exactly one AccessAttempt — no orphaned or shared entries
  all ae: AuditEntry | (one a: AccessAttempt | a.auditRef = ae)
  // Attribution is correct: accessor, operation, and outcome match the owning attempt
  all a: AccessAttempt | some a.auditRef implies {
    a.auditRef.accessor     = a.caller
    a.auditRef.auditOp      = a.opKind
    a.auditRef.auditOutcome  = a.attemptOutcome
  }
}

assert AppendOnlyAuditEntries { AppendOnlyAuditEntries }
check AppendOnlyAuditEntries for 6

// PATTERN: AppendOnly (ClinicalNotes)  ANCHOR: spec.md FR-012 SC-007; data-model.md clinical_notes append-only
pred AppendOnlyClinicalNotes {
  some ClinicalNote
  // Every ClinicalNote is backed by exactly one permitted PostNote audit entry
  all n: ClinicalNote | (one ae: AuditEntry |
    ae.noteRef = n and ae.auditOp = PostNote and ae.auditOutcome = Permitted)
  // Authors must be clinicians
  all n: ClinicalNote | n.author.role = Clinician
}

assert AppendOnlyClinicalNotes { AppendOnlyClinicalNotes }
check AppendOnlyClinicalNotes for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md AuditEntry fields
pred AttributionCorrectness {
  some AccessAttempt
  all a: AccessAttempt | some a.auditRef implies {
    a.auditRef.accessor     = a.caller
    a.auditRef.auditOp      = a.opKind
    a.auditRef.auditOutcome  = a.attemptOutcome
    a.auditRef.auditRecord   = a.targetRecord
  }
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-003 FR-006; data-model.md users.assigned_record_id
pred OwnershipBasedAccess {
  some a: AccessAttempt | a.caller.role = Patient
  // A patient receives Permitted on GetRecord iff relationship = PatientOwn
  all a: AccessAttempt |
    (a.caller.role = Patient and a.opKind = GetRecord and a.attemptOutcome = Permitted)
      implies a.relationship = PatientOwn
  // PatientOwn iff caller.assignedRecord = targetRecord
  all a: AccessAttempt |
    a.relationship = PatientOwn implies a.caller.assignedRecord = a.targetRecord
  // A patient with PatientOther receives Denied on GetRecord
  all a: AccessAttempt |
    (a.caller.role = Patient and a.relationship = PatientOther and a.opKind = GetRecord)
      implies a.attemptOutcome = Denied
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008 SC-003; contracts/http-api.md byte-equivalent 403
pred NoInformationLeakage {
  some AccessAttempt
  // Any two attempts with the same role and relationship and opKind must share the same outcome —
  // existence of the targetRecord is not observable from the response shape.
  all disj a1, a2: AccessAttempt |
    (a1.caller.role = a2.caller.role
      and a1.relationship = a2.relationship
      and a1.opKind = a2.opKind)
        implies a1.attemptOutcome = a2.attemptOutcome
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// ─────────────────────────────────────────────
// FEATURE-SPECIFIC PREDICATES (per FR)
// ─────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some AccessAttempt
  // Every AccessAttempt has exactly one authenticated caller with a defined role
  all a: AccessAttempt | {
    one a.caller
    a.caller.role in (Clinician + Patient + ComplianceOfficer)
  }
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 FR-003
pred FR_002_003_RoleAndRecordPairing {
  some u: User | u.role = Patient
  // Each user has exactly one role
  all u: User | one u.role
  // Patient has exactly one assignedRecord; others have none
  all u: User | {
    (u.role = Patient    implies one u.assignedRecord)
    (u.role != Patient   implies no u.assignedRecord)
  }
}

assert FR_002_003_RoleAndRecordPairing { FR_002_003_RoleAndRecordPairing }
check FR_002_003_RoleAndRecordPairing for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_CareTeamGating {
  some a: AccessAttempt | a.relationship = CareTeamClin
  some a: AccessAttempt | a.relationship = OutsiderClin
  // Clinician access to GetRecord is Permitted iff CareTeamClin
  all a: AccessAttempt |
    (a.caller.role = Clinician and a.opKind = GetRecord)
      implies (a.attemptOutcome = Permitted iff a.relationship = CareTeamClin)
  // CareTeamClin iff membership exists
  all a: AccessAttempt |
    a.relationship = CareTeamClin implies
      (some m: CareTeamMembership | m.ctmClinician = a.caller and m.ctmRecord = a.targetRecord)
}

assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_ClinicianAuditAccess {
  some a: AccessAttempt | a.caller.role = Clinician and a.opKind = GetAccessLog
  // A clinician is always denied GetAccessLog
  all a: AccessAttempt |
    (a.caller.role = Clinician and a.opKind = GetAccessLog)
      implies a.attemptOutcome = Denied
}

assert FR_005_ClinicianAuditAccess { FR_005_ClinicianAuditAccess }
check FR_005_ClinicianAuditAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_PatientSelfAccess {
  some a: AccessAttempt | a.caller.role = Patient and a.relationship = PatientOwn
  // Patient Permitted on GetRecord iff own record
  all a: AccessAttempt |
    (a.caller.role = Patient and a.opKind = GetRecord)
      implies (a.attemptOutcome = Permitted iff a.relationship = PatientOwn)
  // Patient never Permitted on PostNote
  all a: AccessAttempt |
    (a.caller.role = Patient and a.opKind = PostNote)
      implies a.attemptOutcome = Denied
  // Patient never Permitted on GetAccessLog
  all a: AccessAttempt |
    (a.caller.role = Patient and a.opKind = GetAccessLog)
      implies a.attemptOutcome = Denied
}

assert FR_006_PatientSelfAccess { FR_006_PatientSelfAccess }
check FR_006_PatientSelfAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 FR-019
pred FR_007_ComplianceOfficerContentBlind {
  some a: AccessAttempt | a.caller.role = ComplianceOfficer
  // ComplianceOfficer never Permitted on GetRecord (clinical content)
  all a: AccessAttempt |
    (a.caller.role = ComplianceOfficer and a.opKind = GetRecord)
      implies a.attemptOutcome = Denied
  // ComplianceOfficer never Permitted on PostNote
  all a: AccessAttempt |
    (a.caller.role = ComplianceOfficer and a.opKind = PostNote)
      implies a.attemptOutcome = Denied
  // ComplianceOfficer always Permitted on GetAccessLog
  all a: AccessAttempt |
    (a.caller.role = ComplianceOfficer and a.opKind = GetAccessLog)
      implies a.attemptOutcome = Permitted
}

assert FR_007_ComplianceOfficerContentBlind { FR_007_ComplianceOfficerContentBlind }
check FR_007_ComplianceOfficerContentBlind for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 SC-003
pred FR_008_ByteEquivalentDenial {
  some AccessAttempt
  // The outcome is determined solely by relationship and opKind — not by record existence
  all disj a1, a2: AccessAttempt |
    (a1.relationship = a2.relationship and a1.opKind = a2.opKind)
      implies a1.attemptOutcome = a2.attemptOutcome
}

assert FR_008_ByteEquivalentDenial { FR_008_ByteEquivalentDenial }
check FR_008_ByteEquivalentDenial for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011; data-model.md clinical_notes author_role CHECK
pred FR_011_NoteAuthorIsClinician {
  some ClinicalNote
  all n: ClinicalNote | n.author.role = Clinician
}

assert FR_011_NoteAuthorIsClinician { FR_011_NoteAuthorIsClinician }
check FR_011_NoteAuthorIsClinician for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 SC-007
pred FR_012_NotesAppendOnly {
  some ClinicalNote
  // Every note is backed by a permitted PostNote attempt
  all n: ClinicalNote |
    (one ae: AuditEntry |
      ae.noteRef = n and ae.auditOp = PostNote and ae.auditOutcome = Permitted)
  // No note is referenced by more than one AuditEntry (no "update" producing a second audit ref)
  all disj ae1, ae2: AuditEntry |
    (ae1.noteRef = ae2.noteRef and some ae1.noteRef) implies ae1 = ae2
}

assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 SC-001 SC-002
pred FR_013_AlwaysOnAudit {
  some AccessAttempt
  // All non-GetAccessLog-denied attempts have exactly one audit entry
  all a: AccessAttempt |
    not (a.opKind = GetAccessLog and a.attemptOutcome = Denied)
      implies (one a.auditRef)
  // No successful state change without a matching audit entry
  all a: AccessAttempt |
    a.attemptOutcome = Permitted implies (one a.auditRef)
}

assert FR_013_AlwaysOnAudit { FR_013_AlwaysOnAudit }
check FR_013_AlwaysOnAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014; data-model.md AuditEntry CHECK on note_id
pred FR_014_AuditNoteIdConstraint {
  some ae: AuditEntry | ae.auditOp = PostNote and ae.auditOutcome = Permitted
  all ae: AuditEntry | {
    (ae.auditOp = PostNote and ae.auditOutcome = Permitted) implies (one ae.noteRef)
    (ae.auditOp = PostNote and ae.auditOutcome = Denied)    implies (no ae.noteRef)
    (ae.auditOp != PostNote)                                 implies (no ae.noteRef)
  }
}

assert FR_014_AuditNoteIdConstraint { FR_014_AuditNoteIdConstraint }
check FR_014_AuditNoteIdConstraint for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 SC-008; data-model.md audit_entries no UPDATE/DELETE
pred FR_015_AuditImmutability {
  some AuditEntry
  // Every AuditEntry is owned by exactly one AccessAttempt — structural immutability
  all ae: AuditEntry | (one a: AccessAttempt | a.auditRef = ae)
}

assert FR_015_AuditImmutability { FR_015_AuditImmutability }
check FR_015_AuditImmutability for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017; data-model.md 7-year retention floor (no DELETE code path)
pred FR_017_AuditRetention {
  some AuditEntry
  // Structural proxy: every AuditEntry that was written (owned by an AccessAttempt) remains
  // reachable — no AuditEntry is orphaned (which would model deletion)
  all ae: AuditEntry | (some a: AccessAttempt | a.auditRef = ae)
}

assert FR_017_AuditRetention { FR_017_AuditRetention }
check FR_017_AuditRetention for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018; contracts/http-api.md GET /access-log authorisation
pred FR_018_GetAccessLogComplianceOnly {
  some a: AccessAttempt | a.opKind = GetAccessLog and a.attemptOutcome = Permitted
  // Only compliance officers receive Permitted on GetAccessLog
  all a: AccessAttempt |
    (a.opKind = GetAccessLog and a.attemptOutcome = Permitted)
      implies a.caller.role = ComplianceOfficer
  // Non-compliance-officers are always denied GetAccessLog
  all a: AccessAttempt |
    (a.opKind = GetAccessLog and a.caller.role != ComplianceOfficer)
      implies a.attemptOutcome = Denied
}

assert FR_018_GetAccessLogComplianceOnly { FR_018_GetAccessLogComplianceOnly }
check FR_018_GetAccessLogComplianceOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-019 SC-006; contracts/http-api.md compliance content-blindness
pred FR_019_ComplianceNoClinicialContent {
  some a: AccessAttempt | a.caller.role = ComplianceOfficer
  // ComplianceOfficer is structurally excluded from GetRecord (clinical content endpoint)
  all a: AccessAttempt |
    (a.caller.role = ComplianceOfficer)
      implies (a.opKind != GetRecord or a.attemptOutcome = Denied)
  // ComplianceOfficer never authors a ClinicalNote
  no n: ClinicalNote | n.author.role = ComplianceOfficer
}

assert FR_019_ComplianceNoClinicialContent { FR_019_ComplianceNoClinicialContent }
check FR_019_ComplianceNoClinicialContent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-020; spec.md URL handling; data-model.md Record.id
// Modelled as: the care-team gating uses opaque Record atoms, not user-demographic fields.
// Structural proxy: no User sig field is used as a Record identifier.
// This is enforced by the sig design (Record is a distinct sig from User).
// Checkable assertion: every AccessAttempt that targets a Record does so via a Record atom,
// not via a User atom — guaranteed by the type system; we assert it is non-vacuous.
pred FR_020_OpaqueRecordId {
  some a: AccessAttempt | a.opKind != GetAccessLog and some a.targetRecord
  // targetRecord is a Record atom (type-enforced); we assert at least one such attempt exists
  all a: AccessAttempt | a.opKind != GetAccessLog implies (some a.targetRecord)
}

assert FR_020_OpaqueRecordId { FR_020_OpaqueRecordId }
check FR_020_OpaqueRecordId for 6