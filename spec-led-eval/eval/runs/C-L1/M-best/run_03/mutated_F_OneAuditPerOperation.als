// === feature_model.als — Alloy model for 009-clinician-record-access (C-L1) ===
//
// Self-contained Alloy 6 model. Encodes the structural invariants of the
// "clinicians read patient records, gated by care-team membership, audited
// on every attempt, byte-equivalent denial response" feature.

// ---------- Roles (FR-002 catalogue) ----------
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends Role {}

// ---------- Operation kinds (endpoints) ----------
abstract sig OperationKind {}
one sig LookupPatient, AuditSearch extends OperationKind {}

// ---------- Outcomes ----------
abstract sig Outcome {}
one sig Permitted, Denied, NotFoundOrDenied,
        Unauthenticated, ValidationError, ServiceUnavailable extends Outcome {}

// ---------- Authorisation bases ----------
abstract sig AuthBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound, NoBasis extends AuthBasis {}

// ---------- External response (byte-equivalence carrier) ----------
abstract sig ExternalResponse {}
one sig OK200, NotFound404, Unauth401, BadReq400, Unavail503 extends ExternalResponse {}

// ---------- Bool (body-valid flag) ----------
abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

// ---------- Entities ----------
sig User { role: one Role }

sig Patient {}

sig CareTeamMembership {
  member:     one User,
  forPatient: one Patient
}

sig Operation {
  kind:       one OperationKind,
  caller:     lone User,
  requested:  lone Patient,
  bodyValid:  one Bool,
  outcome:    one Outcome,
  basis:      one AuthBasis,
  visible:    one ExternalResponse
}

sig AuditEntry {
  ofOp:         one Operation,
  recClinician: one User,
  recRole:      one Role,
  recOutcome:   one Outcome,
  recBasis:     one AuthBasis
}

// ---------- Permission matrix as a singleton-sig field ----------
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Non-empty universe (single declaration; no witnesses in preds) ----------
fact F_NonEmptyUniverse {
  some User
  some Patient
  some Operation
  some AuditEntry
  some CareTeamMembership
}

// ---------- Permission matrix encoding (closed-world) ----------
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor        -> LookupPatient) +
    (Nurse         -> LookupPatient) +
    (Pharmacist    -> LookupPatient) +
    (ClinicalAdmin -> LookupPatient) +
    (AuditOfficer  -> AuditSearch)
}

// ---------- Outcome <-> visible response mapping ----------
fact F_VisibleResponseMapping {
  all op: Operation {
    (op.outcome = Permitted)          iff (op.visible = OK200)
    (op.outcome = Unauthenticated)    iff (op.visible = Unauth401)
    (op.outcome = ValidationError)    iff (op.visible = BadReq400)
    (op.outcome = ServiceUnavailable) iff (op.visible = Unavail503)
    (op.outcome in (Denied + NotFoundOrDenied)) iff (op.visible = NotFound404)
  }
}

// ---------- Authentication boundary (FR-001) ----------
fact F_AuthenticationBoundary {
  all op: Operation | (no op.caller) iff op.outcome = Unauthenticated
}

// ---------- Validation gate ----------
fact F_ValidationGate {
  all op: Operation |
    (some op.caller and op.bodyValid = BFalse) iff op.outcome = ValidationError
}

// ---------- Care-team membership required for any Permitted lookup (FR-006) ----------
fact F_CareTeamGate {
  all op: Operation |
    (op.kind = LookupPatient and op.outcome = Permitted) implies
      (some op.caller and some op.requested and
       (some m: CareTeamMembership |
          m.member = op.caller and m.forPatient = op.requested))
}

// ---------- Least privilege: Permitted requires an allowed (role, kind) cell ----------
fact F_LeastPrivilegeFact {
  all op: Operation |
    op.outcome = Permitted implies
      (some op.caller and (op.caller.role -> op.kind) in PermMatrix.Allowed)
}

// ---------- Audit-on-lookup: every reached LookupPatient gets at least one audit entry ----------
fact F_AuditOnLookup {
  all op: Operation |
    (op.kind = LookupPatient and some op.caller and op.bodyValid = BTrue
     and op.outcome in (Permitted + Denied + NotFoundOrDenied))
        implies (some ae: AuditEntry | ae.ofOp = op)
  all op: Operation |
    not (op.kind = LookupPatient and some op.caller and op.bodyValid = BTrue
         and op.outcome in (Permitted + Denied + NotFoundOrDenied))
        implies (no ae: AuditEntry | ae.ofOp = op)
}

// ---------- One audit entry per operation (append-only, no duplicates/rewrites) ----------
fact F_OneAuditPerOperation { /* MUTATED — body cleared by validator */ }

// ---------- Audit attribution snapshot ----------
fact F_AuditAttribution {
  all ae: AuditEntry {
    ae.recClinician = ae.ofOp.caller
    ae.recRole      = ae.recClinician.role
    ae.recOutcome   = ae.ofOp.outcome
    ae.recBasis     = ae.ofOp.basis
  }
}

// ---------- Auth-basis labelling for LookupPatient outcomes ----------
fact F_AuthBasisLabelling {
  all op: Operation {
    (op.kind = LookupPatient and op.outcome = Permitted)        implies op.basis = CareTeamMember
    (op.kind = LookupPatient and op.outcome = Denied)           implies op.basis = NotCareTeamMember
    (op.kind = LookupPatient and op.outcome = NotFoundOrDenied) implies op.basis = PatientNotFound
  }
}

// ---------- SLA breach (ServiceUnavailable) means no audit was written ----------
fact F_SLAViolationNoAudit {
  all op: Operation |
    op.outcome = ServiceUnavailable implies (no ae: AuditEntry | ae.ofOp = op)
}

// ===========================================================
// CATALOGUE PATTERNS
// ===========================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth boundary
pred AuthRequiredEverywhere {
  all op: Operation | op.outcome != Unauthenticated implies some op.caller
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md auth tables
pred LeastPrivilege {
  all op: Operation |
    op.outcome = Permitted implies
      (some op.caller and (op.caller.role -> op.kind) in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables
pred PermissionCompleteness {
  Doctor        -> LookupPatient in PermMatrix.Allowed
  Nurse         -> LookupPatient in PermMatrix.Allowed
  Pharmacist    -> LookupPatient in PermMatrix.Allowed
  ClinicalAdmin -> LookupPatient in PermMatrix.Allowed
  AuditOfficer  -> AuditSearch   in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: PermissionGrounding  ANCHOR: contracts/http-api.md "no silent grants"
pred PermissionGrounding {
  PermMatrix.Allowed in
    (Doctor        -> LookupPatient) +
    (Nurse         -> LookupPatient) +
    (Pharmacist    -> LookupPatient) +
    (ClinicalAdmin -> LookupPatient) +
    (AuditOfficer  -> AuditSearch)
  AuditOfficer  -> LookupPatient not in PermMatrix.Allowed
  Doctor        -> AuditSearch   not in PermMatrix.Allowed
  Nurse         -> AuditSearch   not in PermMatrix.Allowed
  Pharmacist    -> AuditSearch   not in PermMatrix.Allowed
  ClinicalAdmin -> AuditSearch   not in PermMatrix.Allowed
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, FR-009; SC-001, SC-002
pred AuditCompleteness {
  all op: Operation |
    (op.kind = LookupPatient and some op.caller and op.bodyValid = BTrue
     and op.outcome in (Permitted + Denied + NotFoundOrDenied))
        implies (one ae: AuditEntry | ae.ofOp = op)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  all disj ae1, ae2: AuditEntry | ae1.ofOp != ae2.ofOp
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009 snapshot semantics
pred AttributionCorrectness {
  all ae: AuditEntry {
    ae.recClinician = ae.ofOp.caller
    ae.recRole      = ae.recClinician.role
    ae.recOutcome   = ae.ofOp.outcome
  }
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006 (care-team membership)
pred OwnershipBasedAccess {
  all op: Operation |
    (op.kind = LookupPatient and op.outcome = Permitted) implies
      (some m: CareTeamMembership |
         m.member = op.caller and m.forPatient = op.requested)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003, SC-011
pred NoInformationLeakage {
  all op: Operation |
    op.outcome in (Denied + NotFoundOrDenied) implies op.visible = NotFound404
  all op: Operation |
    op.outcome = Permitted implies op.visible != NotFound404
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: contracts/http-api.md validation_error path
pred ValidationBeforeMutation {
  all op: Operation |
    op.outcome = ValidationError implies (no ae: AuditEntry | ae.ofOp = op)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ===========================================================
// FEATURE-SPECIFIC FR ASSERTIONS
// ===========================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all op: Operation | (no op.caller) iff op.outcome = Unauthenticated
  all op: Operation | op.outcome = Unauthenticated implies (no ae: AuditEntry | ae.ofOp = op)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_HostProvidedIdentity {
  all ae: AuditEntry | ae.recRole = ae.recClinician.role
}
assert FR_002_HostProvidedIdentity { FR_002_HostProvidedIdentity }
check FR_002_HostProvidedIdentity for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 (audit data model supports per-patient query)
pred FR_003_AuditPerPatientQueryable {
  all ae: AuditEntry | ae.ofOp.kind = LookupPatient
}
assert FR_003_AuditPerPatientQueryable { FR_003_AuditPerPatientQueryable }
check FR_003_AuditPerPatientQueryable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 (no patient_id in URL paths — closed endpoint set)
pred FR_004_NoPatientIdInUrlPath {
  all op: Operation | op.kind in (LookupPatient + AuditSearch)
}
assert FR_004_NoPatientIdInUrlPath { FR_004_NoPatientIdInUrlPath }
check FR_004_NoPatientIdInUrlPath for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 (read-only — only the two read endpoints can succeed)
pred FR_005_ReadOnly {
  all op: Operation | op.outcome = Permitted implies op.kind in (LookupPatient + AuditSearch)
}
assert FR_005_ReadOnly { FR_005_ReadOnly }
check FR_005_ReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_CareTeamMembershipRequired {
  all op: Operation |
    (op.kind = LookupPatient and op.outcome = Permitted) implies
      (some m: CareTeamMembership |
         m.member = op.caller and m.forPatient = op.requested)
}
assert FR_006_CareTeamMembershipRequired { FR_006_CareTeamMembershipRequired }
check FR_006_CareTeamMembershipRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_ByteEquivalentDeniedNotFound {
  all op: Operation | op.outcome = Denied           implies op.visible = NotFound404
  all op: Operation | op.outcome = NotFoundOrDenied implies op.visible = NotFound404
}
assert FR_007_ByteEquivalentDeniedNotFound { FR_007_ByteEquivalentDeniedNotFound }
check FR_007_ByteEquivalentDeniedNotFound for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_AuditOnEveryAttempt {
  all op: Operation |
    (op.kind = LookupPatient and some op.caller and op.bodyValid = BTrue
     and op.outcome in (Permitted + Denied + NotFoundOrDenied))
        implies (one ae: AuditEntry | ae.ofOp = op)
}
assert FR_008_AuditOnEveryAttempt { FR_008_AuditOnEveryAttempt }
check FR_008_AuditOnEveryAttempt for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_AuditEntryShape {
  all ae: AuditEntry {
    ae.recClinician = ae.ofOp.caller
    ae.recRole      = ae.recClinician.role
    ae.recOutcome   = ae.ofOp.outcome
    ae.recBasis     = ae.ofOp.basis
  }
}
assert FR_009_AuditEntryShape { FR_009_AuditEntryShape }
check FR_009_AuditEntryShape for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_AuditImmutable {
  all disj ae1, ae2: AuditEntry | ae1.ofOp != ae2.ofOp
}
assert FR_010_AuditImmutable { FR_010_AuditImmutable }
check FR_010_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_AuditOnlyByIG {
  all op: Operation |
    (op.kind = AuditSearch and op.outcome = Permitted) implies op.caller.role = AuditOfficer
}
assert FR_011_AuditOnlyByIG { FR_011_AuditOnlyByIG }
check FR_011_AuditOnlyByIG for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 (no deletion path)
pred FR_012_NoDeletionPath {
  all disj ae1, ae2: AuditEntry | ae1.ofOp != ae2.ofOp
}
assert FR_012_NoDeletionPath { FR_012_NoDeletionPath }
check FR_012_NoDeletionPath for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 (2-second SLA; SU iff no audit written)
pred FR_013_SLAAudit {
  all op: Operation |
    (op.kind = LookupPatient and op.outcome = Permitted) implies
      (one ae: AuditEntry | ae.ofOp = op)
  all op: Operation |
    op.outcome = ServiceUnavailable implies (no ae: AuditEntry | ae.ofOp = op)
}
assert FR_013_SLAAudit { FR_013_SLAAudit }
check FR_013_SLAAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014, FR-015 (safety block surfaced on every successful read)
pred FR_014_15_SafetyBlocksAtTop {
  all op: Operation |
    (op.kind = LookupPatient and op.outcome = Permitted) implies op.visible = OK200
}
assert FR_014_15_SafetyBlocksAtTop { FR_014_15_SafetyBlocksAtTop }
check FR_014_15_SafetyBlocksAtTop for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_DuplicateAudit { some disj ae1, ae2: AuditEntry | ae1.ofOp = ae2.ofOp }
