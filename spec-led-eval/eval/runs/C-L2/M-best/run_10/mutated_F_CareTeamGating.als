// === feature_model.als — Alloy model for Hospital Clinical Record Access ===
// Self-contained Alloy 6 model for feature C-L2 (012-hospital-clinical-records).
// Encodes: care-team gating, append-only notes/audit, byte-equivalent denial,
// audit completeness/attribution, validation-before-mutation, admin content-blindness.

// ---------- Static enums (one sigs) ----------

abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator extends Role {}

fun ClinicalRoles[] : set Role { Doctor + Nurse + Pharmacist + ClinicalAdmin }

abstract sig OperationKind {}
one sig ReadRecord, AddNote, ListAudit extends OperationKind {}

abstract sig Outcome {}
one sig Permitted, Denied, NotFoundOrDenied extends Outcome {}

abstract sig ExternalResponse {}
one sig OkContent, NotFoundEnvelope, Unauthenticated401, ValidationErrorResp, ServiceUnavailable extends ExternalResponse {}

abstract sig AuthStatus {}
one sig Authenticated, Unauthenticated extends AuthStatus {}

abstract sig ValStatus {}
one sig Valid, Invalid extends ValStatus {}

abstract sig MembershipStatus {}
one sig ActiveMembership, EndedMembership extends MembershipStatus {}

// ---------- Dynamic sigs ----------

sig User { role: one Role }
sig Patient {}

sig CareTeamMembership {
  clinician: one User,
  patient: one Patient,
  mstatus: one MembershipStatus
}

sig ClinicalNote {
  notePatient: one Patient,
  author: one User,
  authorRoleSnapshot: one Role
}

sig AuditEntry {
  recordedUser: one User,
  recordedRole: one Role,
  recordedPatient: one Patient,
  recordedKind: one OperationKind,
  recordedOutcome: one Outcome,
  recordedNote: lone ClinicalNote
}

sig Operation {
  caller: one User,
  targetPatient: one Patient,
  kind: one OperationKind,
  outcome: one Outcome,
  authStatus: one AuthStatus,
  valStatus: one ValStatus,
  externalResponse: one ExternalResponse,
  resultingNote: lone ClinicalNote,
  audit: lone AuditEntry
}

// Permission matrix as a singleton sig field
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Non-empty universe ----------

fact F_NonEmptyUniverse {
  some User
  some Patient
  some Operation
  some AuditEntry
  some CareTeamMembership
  some ClinicalNote
}

// ---------- Permission matrix (contracts/http-api.md) ----------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    Doctor -> ReadRecord + Doctor -> AddNote +
    Nurse -> ReadRecord + Nurse -> AddNote +
    Pharmacist -> ReadRecord + Pharmacist -> AddNote +
    ClinicalAdmin -> ReadRecord + ClinicalAdmin -> AddNote +
    HospitalAdministrator -> ListAudit
}

// ---------- Behavioural facts (load-bearing) ----------

// FR-001: authentication boundary; unauthenticated requests reach nothing
fact F_AuthBoundary {
  all op: Operation |
    op.authStatus = Unauthenticated implies
      (op.outcome != Permitted and
       op.externalResponse = Unauthenticated401 and
       no op.audit and
       no op.resultingNote)
}

// FR-004 + FR-005: clinical access requires clinical role + active care-team membership
fact F_CareTeamGating { /* MUTATED — body cleared by validator */ }

// FR-005 + FR-017: only HospitalAdministrator may use ListAudit
fact F_AdminOnlyAudit {
  all op: Operation |
    (op.outcome = Permitted and op.kind = ListAudit) implies
      op.caller.role = HospitalAdministrator
}

// FR-006: byte-equivalent denial envelope; permitted returns OkContent
fact F_ByteEquivalentDenial {
  all op: Operation |
    (op.authStatus = Authenticated and op.valStatus = Valid and op.outcome != Permitted)
      implies op.externalResponse = NotFoundEnvelope
  all op: Operation |
    op.outcome = Permitted implies op.externalResponse = OkContent
}

// FR-009: validation before mutation; invalid requests touch nothing
fact F_ValidationBeforeMutation {
  all op: Operation |
    op.valStatus = Invalid implies
      (no op.resultingNote and
       op.outcome != Permitted and
       op.externalResponse = ValidationErrorResp and
       no op.audit)
}

// FR-010/FR-011: notes are created only by permitted AddNote ops with correct attribution
fact F_NoteCreation {
  all n: ClinicalNote | one op: Operation | op.resultingNote = n
  all op: Operation |
    some op.resultingNote implies
      (op.kind = AddNote and
       op.outcome = Permitted and
       op.resultingNote.notePatient = op.targetPatient and
       op.resultingNote.author = op.caller and
       op.resultingNote.authorRoleSnapshot = op.caller.role)
}

// FR-005 (data-model CHECK): no clinical note may carry HospitalAdministrator as author role
fact F_NoAdminAuthoredNotes {
  no n: ClinicalNote | n.authorRoleSnapshot = HospitalAdministrator
}

// FR-012 + FR-015: every authenticated+validated clinical attempt produces exactly one audit,
// except a non-admin attempt against the audit-list endpoint (which is unsignalled).
fact F_AuditCompleteness {
  all a: AuditEntry | one op: Operation | op.audit = a
  all op: Operation |
    (op.authStatus = Authenticated and op.valStatus = Valid and
     not (op.kind = ListAudit and op.outcome != Permitted))
      implies one op.audit
}

// FR-013: audit entries faithfully reflect the operation that produced them
fact F_AuditAttribution {
  all op: Operation |
    some op.audit implies
      (op.audit.recordedUser = op.caller and
       op.audit.recordedRole = op.caller.role and
       op.audit.recordedPatient = op.targetPatient and
       op.audit.recordedKind = op.kind and
       op.audit.recordedOutcome = op.outcome and
       op.audit.recordedNote = op.resultingNote)
}

// FR-013: note_id appears in an audit entry iff (AddNote AND Permitted)
fact F_AuditNoteIdShape {
  all a: AuditEntry |
    some a.recordedNote iff (a.recordedKind = AddNote and a.recordedOutcome = Permitted)
}

// ============================================================
//                Predicates and assertions
// ============================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md perm tables; spec.md FR-004, FR-005, FR-017
pred LeastPrivilege {
  all op: Operation |
    op.outcome = Permitted implies op.caller.role -> op.kind in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6 but exactly 5 Role, exactly 3 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables
pred PermissionCompleteness {
  // every role has at least one defined permission
  all r: Role | some k: OperationKind | r -> k in PermMatrix.Allowed
  // ListAudit is admin-only
  all r: Role | (r -> ListAudit in PermMatrix.Allowed) implies r = HospitalAdministrator
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6 but exactly 5 Role, exactly 3 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  all op: Operation | op.outcome = Permitted implies op.authStatus = Authenticated
  all op: Operation | op.authStatus = Unauthenticated implies no op.audit
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  all op: Operation |
    (op.outcome = Permitted and op.kind in (ReadRecord + AddNote)) implies
      (some m: CareTeamMembership |
        m.clinician = op.caller and
        m.patient = op.targetPatient and
        m.mstatus = ActiveMembership)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012; data-model.md audit_entries
pred AuditCompleteness {
  all a: AuditEntry | one op: Operation | op.audit = a
  all op: Operation |
    (op.authStatus = Authenticated and op.valStatus = Valid and
     not (op.kind = ListAudit and op.outcome != Permitted))
      implies one op.audit
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011, FR-014; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  // every clinical note is bound to exactly one creating operation
  all n: ClinicalNote | one op: Operation | op.resultingNote = n
  // every audit entry is bound to exactly one creating operation
  all a: AuditEntry | one op: Operation | op.audit = a
  // operations never share an audit entry or a clinical note
  all disj op1, op2: Operation |
    (some op1.audit implies op1.audit != op2.audit) and
    (some op1.resultingNote implies op1.resultingNote != op2.resultingNote)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013; data-model.md AuditEntry fields
pred AttributionCorrectness {
  all op: Operation |
    some op.audit implies
      (op.audit.recordedUser = op.caller and
       op.audit.recordedRole = op.caller.role and
       op.audit.recordedPatient = op.targetPatient and
       op.audit.recordedKind = op.kind and
       op.audit.recordedOutcome = op.outcome)
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006; contracts/http-api.md byte-equivalent envelope
pred NoInformationLeakage {
  all op1, op2: Operation |
    (op1.authStatus = Authenticated and op1.valStatus = Valid and op1.outcome = Denied and
     op2.authStatus = Authenticated and op2.valStatus = Valid and op2.outcome = NotFoundOrDenied)
      implies op1.externalResponse = op2.externalResponse
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-009; data-model.md note CHECKs
pred ValidationBeforeMutation {
  all op: Operation |
    op.valStatus = Invalid implies
      (no op.resultingNote and op.outcome != Permitted and no op.audit)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 6

// FEATURE-SPECIFIC  ANCHOR: FR-001 Authentication required
pred FR_001_AuthRequired {
  all op: Operation | op.outcome = Permitted implies op.authStatus = Authenticated
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 Five-role catalogue
pred FR_002_RoleCatalogue {
  Role = Doctor + Nurse + Pharmacist + ClinicalAdmin + HospitalAdministrator
  all u: User | one u.role
}
assert FR_002_RoleCatalogue { FR_002_RoleCatalogue }
check FR_002_RoleCatalogue for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 Care-team gating
pred FR_004_CareTeamGating {
  all op: Operation |
    (op.outcome = Permitted and op.kind in (ReadRecord + AddNote)) implies
      (op.caller.role in ClinicalRoles[] and
       (some m: CareTeamMembership |
         m.clinician = op.caller and
         m.patient = op.targetPatient and
         m.mstatus = ActiveMembership))
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 Administrator content-blindness (no clinical content path)
pred FR_005_AdminContentBlind {
  no n: ClinicalNote | n.authorRoleSnapshot = HospitalAdministrator
  all op: Operation |
    op.caller.role = HospitalAdministrator implies no op.resultingNote
}
assert FR_005_AdminContentBlind { FR_005_AdminContentBlind }
check FR_005_AdminContentBlind for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 Byte-equivalent unauthorised response
pred FR_006_ByteEquivalentDenial {
  all op: Operation |
    (op.authStatus = Authenticated and op.valStatus = Valid and op.outcome != Permitted)
      implies op.externalResponse = NotFoundEnvelope
}
assert FR_006_ByteEquivalentDenial { FR_006_ByteEquivalentDenial }
check FR_006_ByteEquivalentDenial for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 Note submission validation
pred FR_009_NoteValidation {
  all op: Operation |
    (op.kind = AddNote and op.valStatus = Invalid) implies
      (no op.resultingNote and op.outcome != Permitted)
}
assert FR_009_NoteValidation { FR_009_NoteValidation }
check FR_009_NoteValidation for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 Note shape + author/role snapshot
pred FR_010_NoteShape {
  all n: ClinicalNote |
    some op: Operation |
      (op.resultingNote = n and
       n.notePatient = op.targetPatient and
       n.author = op.caller and
       n.authorRoleSnapshot = op.caller.role)
}
assert FR_010_NoteShape { FR_010_NoteShape }
check FR_010_NoteShape for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 Notes append-only
pred FR_011_NotesAppendOnly {
  all n: ClinicalNote | one op: Operation | op.resultingNote = n
  all op: Operation |
    some op.resultingNote implies (op.kind = AddNote and op.outcome = Permitted)
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 Always-on audit
pred FR_012_AlwaysOnAudit {
  all op: Operation |
    (op.authStatus = Authenticated and op.valStatus = Valid and
     not (op.kind = ListAudit and op.outcome != Permitted))
      implies one op.audit
  all a: AuditEntry | some op: Operation | op.audit = a
}
assert FR_012_AlwaysOnAudit { FR_012_AlwaysOnAudit }
check FR_012_AlwaysOnAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 Audit entry shape + note_id paired with permitted add_note
pred FR_013_AuditShape {
  all a: AuditEntry |
    some a.recordedNote iff (a.recordedKind = AddNote and a.recordedOutcome = Permitted)
  all op: Operation |
    some op.audit implies op.audit.recordedRole = op.caller.role
}
assert FR_013_AuditShape { FR_013_AuditShape }
check FR_013_AuditShape for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 Audit append-only
pred FR_014_AuditAppendOnly {
  all a: AuditEntry | one op: Operation | op.audit = a
  all disj op1, op2: Operation | some op1.audit implies op1.audit != op2.audit
}
assert FR_014_AuditAppendOnly { FR_014_AuditAppendOnly }
check FR_014_AuditAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 No permitted operation without a matching audit
pred FR_015_NoPermitWithoutAudit {
  all op: Operation | op.outcome = Permitted implies one op.audit
}
assert FR_015_NoPermitWithoutAudit { FR_015_NoPermitWithoutAudit }
check FR_015_NoPermitWithoutAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-016 Audit retention floor — no delete path
pred FR_016_AuditRetention {
  all a: AuditEntry | some op: Operation | op.audit = a
}
assert FR_016_AuditRetention { FR_016_AuditRetention }
check FR_016_AuditRetention for 6

// FEATURE-SPECIFIC  ANCHOR: FR-017 Administrator-only audit-list endpoint
pred FR_017_AdminOnlyAuditEndpoint {
  all op: Operation |
    (op.outcome = Permitted and op.kind = ListAudit) implies
      op.caller.role = HospitalAdministrator
}
assert FR_017_AdminOnlyAuditEndpoint { FR_017_AdminOnlyAuditEndpoint }
check FR_017_AdminOnlyAuditEndpoint for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 Administrator response carries no clinical content
pred FR_018_AdminContentBlindResponse {
  all op: Operation |
    op.caller.role = HospitalAdministrator implies no op.resultingNote
  no n: ClinicalNote | n.author.role = HospitalAdministrator
}
assert FR_018_AdminContentBlindResponse { FR_018_AdminContentBlindResponse }
check FR_018_AdminContentBlindResponse for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_NoMembershipPermitted { some op: Operation | op.kind = ReadRecord and op.outcome = Permitted and op.authStatus = Authenticated and op.valStatus = Valid and op.caller.role = Doctor and (no m: CareTeamMembership | m.clinician = op.caller and m.patient = op.targetPatient and m.mstatus = ActiveMembership) }
