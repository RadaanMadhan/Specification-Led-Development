// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===
// Feature: C-L3 / 013-hipaa-clinical-records
// Sources: spec.md, data-model.md, contracts/http-api.md

// ── Roles ─────────────────────────────────────────────────────────────────────

abstract sig Role {}
one sig Clinician, PatientRole, ComplianceOfficer extends Role {}

// ── Operation kinds (the four exposed endpoints) ──────────────────────────────

abstract sig OperationKind {}
one sig GetRecord       extends OperationKind {} // GET /records/{id}
one sig PostNote        extends OperationKind {} // POST /records/{id}/notes
one sig GetRecordAudit  extends OperationKind {} // GET /records/{id}/audit
one sig GetAccessLog    extends OperationKind {} // GET /access-log

// ── Caller–resource relationship (the conditional dimension of the matrix) ────
// computed by permissions.relationship() on every request (spec.md FR-004/006/007)

abstract sig Relationship {}
one sig CTClinician    extends Relationship {} // clinician with active care-team row
one sig NonCTClinician extends Relationship {} // clinician without care-team row
one sig PatientOwn     extends Relationship {} // patient, {id}==assigned_record_id
one sig PatientOther   extends Relationship {} // patient, {id}!=assigned_record_id
one sig ComplianceRel  extends Relationship {} // compliance_officer (any record)

// ── Outcomes ──────────────────────────────────────────────────────────────────

abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

// ── Dynamic sigs ──────────────────────────────────────────────────────────────

sig User {
  role:           one Role,
  assignedRecord: lone Record  // non-null iff role = PatientRole (FR-003)
}

sig Record {}

// Active care-team membership (FR-004; data-model.md CareTeamMembership)
sig CareTeamMembership {
  ctClinician: one User,
  ctRecord:    one Record
}

// Append-only clinical note (FR-011, FR-012; data-model.md ClinicalNote)
sig ClinicalNote {
  noteRecord: one Record,
  author:     one User
}

// Immutable audit entry (FR-013–017; data-model.md AuditEntry)
sig AuditEntry {
  entryAccessor:  one User,
  entryRole:      one Role,
  entryOp:        one OperationKind,
  entryOutcome:   one Outcome,
  entryRecord:    lone Record   // NULL only for GetAccessLog (spec.md FR-014)
}

// An Operation represents one access attempt (authenticated; produces one AuditEntry)
sig Operation {
  opCaller:   one User,
  opKind:     one OperationKind,
  opTarget:   lone Record,      // absent for GetAccessLog
  opOutcome:  one Outcome,
  opEntry:    one AuditEntry,
  opRelation: one Relationship
}

// ── Permission matrix singleton ───────────────────────────────────────────────
// Allowed is (Relationship × OperationKind) cells where access is granted.

one sig PermMatrix {
  Allowed: set Relationship -> OperationKind
}

// ── Non-empty universe ────────────────────────────────────────────────────────

fact F_NonEmptyUniverse {
  some User
  some Record
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
  some Operation
}

// ── Named structural facts ────────────────────────────────────────────────────

// FR-002, FR-003: users have exactly one role; patients carry assigned_record_id;
// non-patients must NOT carry one (data-model.md User CHECK constraint).
fact F_UserRoleConstraint {
  all u: User | u.role = PatientRole  implies one  u.assignedRecord
  all u: User | u.role != PatientRole implies no   u.assignedRecord
}

// FR-003: no two patients share the same assigned record (OwnershipExclusivity)
fact F_PatientRecordExclusivity {
  all disj u1, u2: User |
    (u1.role = PatientRole and u2.role = PatientRole) implies
    u1.assignedRecord != u2.assignedRecord
}

// FR-004: only users with role Clinician appear in CareTeamMembership
fact F_CareTeamMembersAreClinicians {
  all m: CareTeamMembership | m.ctClinician.role = Clinician
}

// FR-004: no duplicate (clinician, record) memberships
fact F_NoDuplicateCareTeamMemberships {
  all disj m1, m2: CareTeamMembership |
    not (m1.ctClinician = m2.ctClinician and m1.ctRecord = m2.ctRecord)
}

// FR-011, FR-012: only an active care-team clinician can be a note author
fact F_NoteAuthorIsActiveCareteamClinician {
  all n: ClinicalNote |
    n.author.role = Clinician and
    (some m: CareTeamMembership | m.ctClinician = n.author and m.ctRecord = n.noteRecord)
}

// FR-013: every Operation maps to a distinct AuditEntry (injective, covers all entries)
fact F_AuditEntryBijection {
  all disj op1, op2: Operation | op1.opEntry != op2.opEntry
  all ae: AuditEntry | some op: Operation | op.opEntry = ae
}

// FR-014: audit entry attribution — entry fields faithfully mirror the Operation
fact F_AuditEntryAttribution {
  all op: Operation |
    op.opEntry.entryAccessor = op.opCaller       and
    op.opEntry.entryRole     = op.opCaller.role  and
    op.opEntry.entryOp       = op.opKind         and
    op.opEntry.entryOutcome  = op.opOutcome
}

// FR-014: record_id in audit entry matches; NULL only for GetAccessLog
fact F_AuditEntryRecordField {
  all op: Operation |
    op.opKind = GetAccessLog  implies no  op.opEntry.entryRecord
  all op: Operation |
    op.opKind != GetAccessLog implies op.opEntry.entryRecord = op.opTarget
}

// FR-002: every AuditEntry's entryRole matches the accessor's actual role
fact F_AuditEntryRoleConsistency {
  all ae: AuditEntry | ae.entryRole = ae.entryAccessor.role
}

// FR-004/006/007: relationship value is consistent with the caller and target
fact F_RelationshipCorrectness {
  all op: Operation |
    op.opRelation = CTClinician implies
      (op.opCaller.role = Clinician and
       some m: CareTeamMembership | m.ctClinician = op.opCaller and m.ctRecord = op.opTarget)
  all op: Operation |
    op.opRelation = NonCTClinician implies
      (op.opCaller.role = Clinician and
       no m: CareTeamMembership | m.ctClinician = op.opCaller and m.ctRecord = op.opTarget)
  all op: Operation |
    op.opRelation = PatientOwn implies
      (op.opCaller.role = PatientRole and op.opCaller.assignedRecord = op.opTarget)
  all op: Operation |
    op.opRelation = PatientOther implies
      (op.opCaller.role = PatientRole and op.opCaller.assignedRecord != op.opTarget)
  all op: Operation |
    op.opRelation = ComplianceRel implies
      op.opCaller.role = ComplianceOfficer
  // role–relationship consistency in the other direction
  all op: Operation |
    op.opCaller.role = Clinician implies
      (op.opRelation = CTClinician or op.opRelation = NonCTClinician)
  all op: Operation |
    op.opCaller.role = PatientRole implies
      (op.opRelation = PatientOwn or op.opRelation = PatientOther)
  all op: Operation |
    op.opCaller.role = ComplianceOfficer implies op.opRelation = ComplianceRel
}

// contracts/http-api.md permission matrix (closed-world; spec.md §Authorisation matrix)
fact F_PermissionMatrix {
  CTClinician   -> GetRecord      in PermMatrix.Allowed
  CTClinician   -> PostNote       in PermMatrix.Allowed
  CTClinician   -> GetRecordAudit in PermMatrix.Allowed
  PatientOwn    -> GetRecord      in PermMatrix.Allowed
  PatientOwn    -> GetRecordAudit in PermMatrix.Allowed
  ComplianceRel -> GetRecordAudit in PermMatrix.Allowed
  ComplianceRel -> GetAccessLog   in PermMatrix.Allowed
  // Closed-world: exactly these seven cells and no others
  PermMatrix.Allowed =
    (CTClinician   -> GetRecord)      +
    (CTClinician   -> PostNote)       +
    (CTClinician   -> GetRecordAudit) +
    (PatientOwn    -> GetRecord)      +
    (PatientOwn    -> GetRecordAudit) +
    (ComplianceRel -> GetRecordAudit) +
    (ComplianceRel -> GetAccessLog)
}

// FR-001/004/006/007: permitted outcomes may only arise from allowed cells
fact F_AuthorisationEnforced { /* MUTATED — body cleared by validator */ }

// Converse: denied outcomes arise from disallowed cells
fact F_DeniedWhenNotAllowed {
  all op: Operation |
    (op.opRelation -> op.opKind not in PermMatrix.Allowed) implies op.opOutcome = Denied
}

// FR-008: byte-equivalent unauthorised response — Denied is the only outcome
// for every (Relationship, OperationKind) cell outside PermMatrix.Allowed.
// In the model we encode this as: two operations with the same kind and same
// caller relationship always produce the same outcome, regardless of whether
// the target record happens to exist.
fact F_ByteEquivalentDenial {
  all op1, op2: Operation |
    (op1.opRelation = op2.opRelation and op1.opKind = op2.opKind) implies
    op1.opOutcome = op2.opOutcome
}

// FR-012: the only OperationKind that creates notes is PostNote; no mutation
// OperationKind exists for ClinicalNote. Modelled as: every ClinicalNote
// has exactly one associated permitted PostNote operation by its author on its record.
fact F_NoteCreationViaPostNoteOnly {
  all n: ClinicalNote |
    one op: Operation |
      op.opKind = PostNote and op.opOutcome = Permitted and
      op.opTarget = n.noteRecord and op.opCaller = n.author
}

// FR-015/017: no OperationKind in this feature removes or updates an AuditEntry.
// Enforced structurally by the absence of a "DeleteAudit" / "UpdateAudit" kind.
// Additional guard: every AuditEntry that exists has a covering Operation, and
// the entryOutcome in the entry can never be altered after insertion.
// The bijection fact (F_AuditEntryBijection) plus attribution (F_AuditEntryAttribution)
// together pin every field of every AuditEntry to its originating Operation.
fact F_AppendOnlyAuditEntries {
  // Once attributed, an entry's outcome cannot be different from its operation's outcome
  all ae: AuditEntry | all op: Operation |
    op.opEntry = ae implies ae.entryOutcome = op.opOutcome
}

// FR-006: a patient's target must be their assigned record when the relationship is PatientOwn
fact F_PatientOwnRecordGating {
  all op: Operation |
    (op.opCaller.role = PatientRole and op.opOutcome = Permitted) implies
    (op.opRelation = PatientOwn and op.opCaller.assignedRecord = op.opTarget)
}

// GetAccessLog operations must have no target record
fact F_GetAccessLogHasNoRecord {
  all op: Operation | op.opKind = GetAccessLog implies no op.opTarget
}

// Non-GetAccessLog operations must have a target record
fact F_RecordScopedOpsHaveTarget {
  all op: Operation | op.opKind != GetAccessLog implies one op.opTarget
}

// ── Predicate / assertion pairs ────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004, FR-006, FR-007
pred LeastPrivilege {
  some Operation
  all op: Operation |
    op.opOutcome = Permitted implies (op.opRelation -> op.opKind in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  // The allowed set has exactly the seven cells mandated by the spec; no undefined or extra cells
  some r: Relationship, ok: OperationKind | r -> ok in PermMatrix.Allowed
  #(PermMatrix.Allowed) = 7
  CTClinician   -> GetRecord      in PermMatrix.Allowed
  CTClinician   -> PostNote       in PermMatrix.Allowed
  CTClinician   -> GetRecordAudit in PermMatrix.Allowed
  PatientOwn    -> GetRecord      in PermMatrix.Allowed
  PatientOwn    -> GetRecordAudit in PermMatrix.Allowed
  ComplianceRel -> GetRecordAudit in PermMatrix.Allowed
  ComplianceRel -> GetAccessLog   in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-004, FR-005, FR-006, FR-007, FR-018; contracts/ permission tables
pred PermissionGrounding {
  // No silent grants: the only allowed cells are those traceable to explicit FRs.
  // NonCTClinician, PatientOther, ComplianceRel->GetRecord, ComplianceRel->PostNote
  // must all be absent from PermMatrix.Allowed.
  some Operation
  NonCTClinician -> GetRecord      not in PermMatrix.Allowed
  NonCTClinician -> PostNote       not in PermMatrix.Allowed
  NonCTClinician -> GetRecordAudit not in PermMatrix.Allowed
  NonCTClinician -> GetAccessLog   not in PermMatrix.Allowed
  PatientOther   -> GetRecord      not in PermMatrix.Allowed
  PatientOther   -> PostNote       not in PermMatrix.Allowed
  PatientOther   -> GetRecordAudit not in PermMatrix.Allowed
  PatientOther   -> GetAccessLog   not in PermMatrix.Allowed
  ComplianceRel  -> GetRecord      not in PermMatrix.Allowed
  ComplianceRel  -> PostNote       not in PermMatrix.Allowed
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md §Authentication
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation | one op.opCaller
  all op: Operation | one op.opCaller.role
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013, SC-001, SC-002; data-model.md AuditEntry
pred AuditCompleteness {
  some Operation
  all op: Operation | one op.opEntry
  all ae: AuditEntry | (one op: Operation | op.opEntry = ae)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012, FR-015; data-model.md "no UPDATE/DELETE" on clinical_notes and audit_entries
pred AppendOnly {
  some ClinicalNote
  some AuditEntry
  // Every AuditEntry's outcome is pinned to its Operation's outcome — no retroactive mutation
  all ae: AuditEntry |
    (one op: Operation | op.opEntry = ae and ae.entryOutcome = op.opOutcome)
  // Every ClinicalNote has exactly one creating operation and no deleting operation
  all n: ClinicalNote |
    (one op: Operation |
       op.opKind = PostNote and op.opOutcome = Permitted and
       op.opTarget = n.noteRecord and op.opCaller = n.author)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md AuditEntry fields
pred AttributionCorrectness {
  some AuditEntry
  all op: Operation |
    op.opEntry.entryAccessor = op.opCaller      and
    op.opEntry.entryRole     = op.opCaller.role and
    op.opEntry.entryOp       = op.opKind        and
    op.opEntry.entryOutcome  = op.opOutcome
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-003; data-model.md User.assigned_record_id
pred OwnershipExclusivity {
  some u: User | u.role = PatientRole
  // Each patient has exactly one assigned record
  all u: User | u.role = PatientRole implies one u.assignedRecord
  // No two patients share a record
  all disj u1, u2: User |
    (u1.role = PatientRole and u2.role = PatientRole) implies
    u1.assignedRecord != u2.assignedRecord
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md User.assigned_record_id; contracts/ patient matrix row
pred OwnershipBasedAccess {
  some op: Operation | op.opCaller.role = PatientRole
  // A patient may only receive Permitted on their own assigned record
  all op: Operation |
    (op.opCaller.role = PatientRole and op.opOutcome = Permitted) implies
    (op.opCaller.assignedRecord = op.opTarget and op.opRelation = PatientOwn)
  // A patient accessing any other record must be Denied
  all op: Operation |
    (op.opCaller.role = PatientRole and op.opRelation = PatientOther) implies
    op.opOutcome = Denied
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008, SC-003; contracts/http-api.md §Byte-equivalent forbidden response
pred NoInformationLeakage {
  some Operation
  // Two operations with the same (Relationship, OperationKind) always produce the same outcome,
  // so a caller cannot distinguish "record exists but unauthorised" from "record does not exist"
  all op1, op2: Operation |
    (op1.opRelation = op2.opRelation and op1.opKind = op2.opKind) implies
    op1.opOutcome = op2.opOutcome
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// ── Feature-specific predicates ───────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequiredNoAuditOnUnauth {
  // Every access attempt modelled as an Operation has an authenticated caller.
  // Unauthenticated requests are rejected at the boundary and produce NO Operation atom —
  // asserted here as: every Operation must have a valid (non-empty) caller with a known role.
  some Operation
  all op: Operation | op.opCaller.role in Role
}
assert FR_001_AuthRequiredNoAuditOnUnauth { FR_001_AuthRequiredNoAuditOnUnauth }
check FR_001_AuthRequiredNoAuditOnUnauth for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_ExactlyOneRolePerUser {
  some User
  all u: User | one u.role
}
assert FR_002_ExactlyOneRolePerUser { FR_002_ExactlyOneRolePerUser }
check FR_002_ExactlyOneRolePerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_PatientAssignedRecord {
  some u: User | u.role = PatientRole
  all u: User | u.role = PatientRole  implies one  u.assignedRecord
  all u: User | u.role != PatientRole implies no   u.assignedRecord
}
assert FR_003_PatientAssignedRecord { FR_003_PatientAssignedRecord }
check FR_003_PatientAssignedRecord for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004; spec.md §Care-team-membership gating
pred FR_004_CareTeamGating {
  some op: Operation | op.opCaller.role = Clinician
  // A clinician's PostNote or GetRecord can only be Permitted when they are on the care team
  all op: Operation |
    (op.opCaller.role = Clinician and
     (op.opKind = GetRecord or op.opKind = PostNote) and
     op.opOutcome = Permitted) implies
    (some m: CareTeamMembership | m.ctClinician = op.opCaller and m.ctRecord = op.opTarget)
  // A clinician NOT on the care team must be Denied for GetRecord and PostNote
  all op: Operation |
    (op.opCaller.role = Clinician and
     (op.opKind = GetRecord or op.opKind = PostNote) and
     (no m: CareTeamMembership | m.ctClinician = op.opCaller and m.ctRecord = op.opTarget)) implies
    op.opOutcome = Denied
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005; spec.md clinician audit access
pred FR_005_ClinicianAuditAccess {
  // A clinician may use GetRecordAudit only when on the care team; must be Denied otherwise
  some Operation
  all op: Operation |
    (op.opCaller.role = Clinician and op.opKind = GetRecordAudit and op.opOutcome = Permitted) implies
    (some m: CareTeamMembership | m.ctClinician = op.opCaller and m.ctRecord = op.opTarget)
  // Clinician is NEVER allowed GetAccessLog
  all op: Operation |
    (op.opCaller.role = Clinician and op.opKind = GetAccessLog) implies op.opOutcome = Denied
}
assert FR_005_ClinicianAuditAccess { FR_005_ClinicianAuditAccess }
check FR_005_ClinicianAuditAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006; spec.md patient self-access
pred FR_006_PatientSelfAccess {
  some op: Operation | op.opCaller.role = PatientRole
  // Patient PostNote always denied
  all op: Operation |
    (op.opCaller.role = PatientRole and op.opKind = PostNote) implies op.opOutcome = Denied
  // Patient GetAccessLog always denied
  all op: Operation |
    (op.opCaller.role = PatientRole and op.opKind = GetAccessLog) implies op.opOutcome = Denied
  // Patient access to own record is permitted; to others is denied
  all op: Operation |
    (op.opCaller.role = PatientRole and
     (op.opKind = GetRecord or op.opKind = GetRecordAudit)) implies
    (op.opOutcome = Permitted iff op.opCaller.assignedRecord = op.opTarget)
}
assert FR_006_PatientSelfAccess { FR_006_PatientSelfAccess }
check FR_006_PatientSelfAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007, FR-019; spec.md compliance officer content-blindness
pred FR_007_ComplianceOfficerDeniedClinicalContent {
  some op: Operation | op.opCaller.role = ComplianceOfficer
  // Compliance officer must be denied GetRecord (clinical content)
  all op: Operation |
    (op.opCaller.role = ComplianceOfficer and op.opKind = GetRecord) implies op.opOutcome = Denied
  // Compliance officer must be denied PostNote
  all op: Operation |
    (op.opCaller.role = ComplianceOfficer and op.opKind = PostNote) implies op.opOutcome = Denied
  // Compliance officer IS permitted GetRecordAudit and GetAccessLog
  ComplianceRel -> GetRecordAudit in PermMatrix.Allowed
  ComplianceRel -> GetAccessLog   in PermMatrix.Allowed
}
assert FR_007_ComplianceOfficerDeniedClinicalContent { FR_007_ComplianceOfficerDeniedClinicalContent }
check FR_007_ComplianceOfficerDeniedClinicalContent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013; spec.md "exactly one audit entry per access event"
pred FR_013_AlwaysOnAudit {
  some Operation
  all op: Operation | one op.opEntry
  all ae: AuditEntry | (one op: Operation | op.opEntry = ae)
  // Audit entries exist for both permitted and denied outcomes
  (some op: Operation | op.opOutcome = Permitted) implies
    (some ae: AuditEntry | ae.entryOutcome = Permitted)
  (some op: Operation | op.opOutcome = Denied) implies
    (some ae: AuditEntry | ae.entryOutcome = Denied)
}
assert FR_013_AlwaysOnAudit { FR_013_AlwaysOnAudit }
check FR_013_AlwaysOnAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014; data-model.md AuditEntry fields; spec.md §Audit entry shape
pred FR_014_AuditEntryShape {
  some AuditEntry
  all ae: AuditEntry |
    one ae.entryAccessor and
    one ae.entryRole     and
    one ae.entryOp       and
    one ae.entryOutcome  and
    ae.entryRole = ae.entryAccessor.role
  // record_id is absent iff the operation is GetAccessLog
  all ae: AuditEntry |
    ae.entryOp = GetAccessLog implies no  ae.entryRecord
  all ae: AuditEntry |
    ae.entryOp != GetAccessLog implies one ae.entryRecord
}
assert FR_014_AuditEntryShape { FR_014_AuditEntryShape }
check FR_014_AuditEntryShape for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015, FR-017; data-model.md "no UPDATE/DELETE on audit_entries"
pred FR_015_AuditImmutability {
  some AuditEntry
  // Every audit entry's fields are fully determined by its originating Operation; no mutation possible.
  all ae: AuditEntry |
    all op: Operation |
      op.opEntry = ae implies
        (ae.entryAccessor = op.opCaller and
         ae.entryRole     = op.opCaller.role and
         ae.entryOp       = op.opKind and
         ae.entryOutcome  = op.opOutcome)
}
assert FR_015_AuditImmutability { FR_015_AuditImmutability }
check FR_015_AuditImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012; spec.md §Append-only clinical notes
pred FR_012_NotesAppendOnly {
  some ClinicalNote
  // Only care-team clinicians author notes
  all n: ClinicalNote | n.author.role = Clinician
  all n: ClinicalNote |
    (some m: CareTeamMembership | m.ctClinician = n.author and m.ctRecord = n.noteRecord)
  // Each note has exactly one creating operation
  all n: ClinicalNote |
    (one op: Operation |
       op.opKind = PostNote and op.opOutcome = Permitted and
       op.opTarget = n.noteRecord and op.opCaller = n.author)
}
assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018; spec.md §Compliance-officer endpoint
pred FR_018_AccessLogComplianceOnly {
  some op: Operation | op.opKind = GetAccessLog
  all op: Operation |
    (op.opKind = GetAccessLog and op.opOutcome = Permitted) implies
    op.opCaller.role = ComplianceOfficer
  all op: Operation |
    (op.opKind = GetAccessLog and op.opCaller.role != ComplianceOfficer) implies
    op.opOutcome = Denied
}
assert FR_018_AccessLogComplianceOnly { FR_018_AccessLogComplianceOnly }
check FR_018_AccessLogComplianceOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-020; spec.md URL handling — record identifiers only in paths
pred FR_020_OpaqueRecordIdsOnly {
  // In the model, Record sigs are opaque atoms — there are no fields carrying demographics.
  // The predicate asserts that operation targets are always Record atoms (not User demographic fields).
  some Operation
  all op: Operation | op.opKind != GetAccessLog implies (one op.opTarget and op.opTarget in Record)
  all op: Operation | op.opKind = GetAccessLog implies no op.opTarget
}
assert FR_020_OpaqueRecordIdsOnly { FR_020_OpaqueRecordIdsOnly }
check FR_020_OpaqueRecordIdsOnly for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_LeastPrivilegeViolation { some op: Operation | op.opRelation = NonCTClinician and op.opKind = GetRecord and op.opOutcome = Permitted }
