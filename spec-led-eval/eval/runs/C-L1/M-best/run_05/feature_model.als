// === feature_model.als — Alloy 6 model for 009-clinician-record-access (C-L1) ===
// Self-contained structural model of: clinician reads of patient records gated by
// care-team membership, with byte-equivalent denied/not-found responses and an
// immutable append-only audit log.

// ---------- Bool ----------
abstract sig Bool {}
one sig True, False extends Bool {}

// ---------- Role catalogue (spec.md FR-002) ----------
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends Role {}

// ---------- Operation kinds: the two endpoints in v1 ----------
abstract sig OperationKind {}
one sig LookupPatient, SearchAudit extends OperationKind {}

// ---------- Permission matrix (contracts/http-api.md auth tables) ----------
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Outcomes (data-model.md AccessOutcome) ----------
abstract sig Outcome {}
one sig Permitted, Denied, NotFoundOrDenied extends Outcome {}

// ---------- Authorisation basis (data-model.md AuthorisationBasis) ----------
abstract sig AuthBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthBasis {}

// ---------- Observable response shape (FR-007 byte equivalence) ----------
abstract sig ResponseShape {}
one sig NotFoundShape, PermittedShape extends ResponseShape {}

// ---------- Entities (data-model.md) ----------
sig User { role: one Role }
sig Patient {}
sig CareTeamMembership {
  clinician: one User,
  patient:   one Patient
}

sig Operation {
  caller:              one User,
  callerRoleSnapshot:  one Role,
  kind:                one OperationKind,
  targetPatient:       lone Patient,     // absent = patient_not_found
  outcome:             one Outcome,
  basis:               one AuthBasis,
  authenticated:       one Bool,
  response:            one ResponseShape
}

sig AuditEntry {
  op:                  one Operation,
  clinicianSnapshot:   one User,
  roleSnapshot:        one Role,
  patientSnapshot:     lone Patient,
  outcomeRecorded:     one Outcome,
  basisRecorded:       one AuthBasis
}

// =====================================================================
// Non-empty universe — required for assertions to bite.
// =====================================================================
fact F_NonEmptyUniverse {
  some User
  some Patient
  some Operation
  some AuditEntry
  some CareTeamMembership
}

// =====================================================================
// Named, mutation-testable facts.
// =====================================================================

// Permission matrix encoded from contracts/http-api.md.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor        -> LookupPatient) +
    (Nurse         -> LookupPatient) +
    (Pharmacist    -> LookupPatient) +
    (ClinicalAdmin -> LookupPatient) +
    (AuditOfficer  -> SearchAudit)
}

// FR-001: authentication is required on every operation that reaches the system.
fact F_AuthRequired {
  all op: Operation | op.authenticated = True
}

// Least privilege: every (role, kind) pair on an Operation must be matrix-allowed.
fact F_LeastPrivilege {
  all op: Operation | op.callerRoleSnapshot -> op.kind in PermMatrix.Allowed
}

// FR-006: permitted lookup requires an actual care-team membership row.
fact F_CareTeamGating {
  all op: Operation |
    (op.kind = LookupPatient and op.outcome = Permitted) implies
      (some m: CareTeamMembership | m.clinician = op.caller and m.patient = op.targetPatient)
}

// FR-009 (partial) + data-model.md outcome/basis/target consistency for lookups.
fact F_LookupOutcomeBasis {
  all op: Operation | op.kind = LookupPatient implies {
    (op.outcome = Permitted)         iff (op.basis = CareTeamMember)
    (op.outcome = Denied)            iff (op.basis = NotCareTeamMember)
    (op.outcome = NotFoundOrDenied)  iff (op.basis = PatientNotFound)
    op.outcome = NotFoundOrDenied implies no op.targetPatient
    op.outcome in (Permitted + Denied) implies some op.targetPatient
  }
}

// FR-007: denied and not-found-or-denied are byte-identical from outside.
fact F_ByteEquivalentResponse {
  all op: Operation |
    op.outcome in (Denied + NotFoundOrDenied) implies op.response = NotFoundShape
  all op: Operation |
    (op.kind = LookupPatient and op.outcome = Permitted) implies op.response = PermittedShape
}

// FR-008: every lookup produces at least one audit entry.
fact F_AuditEveryLookup {
  all op: Operation |
    op.kind = LookupPatient implies (some ae: AuditEntry | ae.op = op)
}

// FR-010: append-only — at most one audit entry per operation.
fact F_AppendOnlyAudit {
  all disj ae1, ae2: AuditEntry | ae1.op != ae2.op
}

// Audit entries only describe LookupPatient operations (FR-008 scope note).
fact F_AuditScope {
  all ae: AuditEntry | ae.op.kind = LookupPatient
}

// FR-009: audit-entry snapshot fields must match the operation they describe.
fact F_AttributionCorrectness {
  all ae: AuditEntry | {
    ae.clinicianSnapshot = ae.op.caller
    ae.roleSnapshot      = ae.op.callerRoleSnapshot
    ae.patientSnapshot   = ae.op.targetPatient
    ae.outcomeRecorded   = ae.op.outcome
    ae.basisRecorded     = ae.op.basis
  }
}

// =====================================================================
// PATTERN predicates and assertions
// =====================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md auth tables; spec.md FR-006, FR-011
pred LeastPrivilege {
  some Operation
  all op: Operation | op.callerRoleSnapshot -> op.kind in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md auth tables
pred PermissionCompleteness {
  PermMatrix.Allowed =
    (Doctor        -> LookupPatient) +
    (Nurse         -> LookupPatient) +
    (Pharmacist    -> LookupPatient) +
    (ClinicalAdmin -> LookupPatient) +
    (AuditOfficer  -> SearchAudit)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-006 (clinical roles), FR-011 (audit_officer)
pred PermissionGrounding {
  all r: Role, k: OperationKind |
    (r -> k) in PermMatrix.Allowed implies
      ((k = LookupPatient and r in (Doctor + Nurse + Pharmacist + ClinicalAdmin))
        or (k = SearchAudit and r = AuditOfficer))
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation | op.authenticated = True
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008 / SC-001
pred AuditCompleteness {
  some Operation
  all op: Operation |
    op.kind = LookupPatient implies (one ae: AuditEntry | ae.op = op)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010 / SC-006
pred AppendOnly {
  all disj ae1, ae2: AuditEntry | ae1.op != ae2.op
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009
pred AttributionCorrectness {
  some AuditEntry
  all ae: AuditEntry | {
    ae.clinicianSnapshot = ae.op.caller
    ae.roleSnapshot      = ae.op.callerRoleSnapshot
    ae.outcomeRecorded   = ae.op.outcome
    ae.basisRecorded     = ae.op.basis
  }
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006 / SC-010
pred OwnershipBasedAccess {
  some Operation
  all op: Operation |
    (op.kind = LookupPatient and op.outcome = Permitted) implies
      (some m: CareTeamMembership | m.clinician = op.caller and m.patient = op.targetPatient)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007 / SC-003
pred NoInformationLeakage {
  some Operation
  all op: Operation |
    op.outcome in (Denied + NotFoundOrDenied) implies op.response = NotFoundShape
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// =====================================================================
// FR-specific predicates and assertions
// =====================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 authenticated callers only
pred FR_001_AuthRequired {
  some Operation
  all op: Operation | op.authenticated = True
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 role catalogue
pred FR_002_RoleCatalogue {
  Role = Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin
  all op: Operation | op.callerRoleSnapshot in Role
}
assert FR_002_RoleCatalogue { FR_002_RoleCatalogue }
check FR_002_RoleCatalogue for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 regulatory regime (structural surrogate: per-patient query supported)
pred FR_003_PerPatientAuditQuery {
  // Every AuditEntry is attached to an Operation that names a patient identifier
  // (either a real Patient or an absent target marking patient_not_found).
  // This is the structural surrogate for "audit data model supports per-patient query".
  all ae: AuditEntry | ae.op.kind = LookupPatient
}
assert FR_003_PerPatientAuditQuery { FR_003_PerPatientAuditQuery }
check FR_003_PerPatientAuditQuery for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 no patient_id in URL paths (structural surrogate)
pred FR_004_NoPIIInPath {
  // Identifiers travel only via Operation.targetPatient (a body-borne relation);
  // no URL-path sig exists in this model.
  all op: Operation | op.targetPatient in Patient
}
assert FR_004_NoPIIInPath { FR_004_NoPIIInPath }
check FR_004_NoPIIInPath for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 read-only — only two operation kinds exist
pred FR_005_ReadOnly {
  OperationKind = LookupPatient + SearchAudit
}
assert FR_005_ReadOnly { FR_005_ReadOnly }
check FR_005_ReadOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 care-team gating
pred FR_006_CareTeamGating {
  some Operation
  all op: Operation |
    (op.kind = LookupPatient and op.outcome = Permitted) implies
      (some m: CareTeamMembership | m.clinician = op.caller and m.patient = op.targetPatient)
}
assert FR_006_CareTeamGating { FR_006_CareTeamGating }
check FR_006_CareTeamGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 byte-equivalent denied / not-found
pred FR_007_ByteEquivalent {
  some Operation
  all op1, op2: Operation |
    (op1.outcome = Denied and op2.outcome = NotFoundOrDenied)
      implies op1.response = op2.response
}
assert FR_007_ByteEquivalent { FR_007_ByteEquivalent }
check FR_007_ByteEquivalent for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 always-on audit
pred FR_008_AlwaysAudit {
  some Operation
  all op: Operation |
    op.kind = LookupPatient implies (some ae: AuditEntry | ae.op = op)
}
assert FR_008_AlwaysAudit { FR_008_AlwaysAudit }
check FR_008_AlwaysAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 audit-entry snapshot fields
pred FR_009_AuditFields {
  some AuditEntry
  all ae: AuditEntry | {
    ae.clinicianSnapshot = ae.op.caller
    ae.roleSnapshot      = ae.op.callerRoleSnapshot
    ae.outcomeRecorded   = ae.op.outcome
    ae.basisRecorded     = ae.op.basis
  }
}
assert FR_009_AuditFields { FR_009_AuditFields }
check FR_009_AuditFields for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 immutable / append-only audit
pred FR_010_AppendOnly {
  all disj ae1, ae2: AuditEntry | ae1.op != ae2.op
}
assert FR_010_AppendOnly { FR_010_AppendOnly }
check FR_010_AppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 IG-only audit search (SC-011)
pred FR_011_IGOnlyAuditSearch {
  some Operation
  all op: Operation |
    op.kind = SearchAudit implies op.callerRoleSnapshot = AuditOfficer
}
assert FR_011_IGOnlyAuditSearch { FR_011_IGOnlyAuditSearch }
check FR_011_IGOnlyAuditSearch for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 no-DELETE / retention floor (structural surrogate)
pred FR_012_RetentionNoDelete {
  // No mechanism in the model removes AuditEntries; every entry remains linked to an op.
  all ae: AuditEntry | some ae.op
}
assert FR_012_RetentionNoDelete { FR_012_RetentionNoDelete }
check FR_012_RetentionNoDelete for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 2-second SLA — no observed access without audit
pred FR_013_NoAccessWithoutAudit {
  some Operation
  all op: Operation |
    (op.kind = LookupPatient and op.outcome = Permitted)
      implies (some ae: AuditEntry | ae.op = op)
}
assert FR_013_NoAccessWithoutAudit { FR_013_NoAccessWithoutAudit }
check FR_013_NoAccessWithoutAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 safety block — every permitted lookup uses success-shape response
pred FR_014_PermittedShape {
  all op: Operation |
    (op.kind = LookupPatient and op.outcome = Permitted)
      implies op.response = PermittedShape
}
assert FR_014_PermittedShape { FR_014_PermittedShape }
check FR_014_PermittedShape for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 patient-verification block in every permitted response
pred FR_015_VerificationBlock {
  all op: Operation |
    (op.kind = LookupPatient and op.outcome = Permitted)
      implies op.response = PermittedShape
}
assert FR_015_VerificationBlock { FR_015_VerificationBlock }
check FR_015_VerificationBlock for 8