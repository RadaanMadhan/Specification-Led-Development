// === feature_model.als — Alloy model for C-L1 (009-clinician-record-access) ===
//
// Encodes the structural invariants of the "clinician access to patient
// medical records" feature: care-team-membership gated read access, always-on
// immutable audit, byte-equivalent deny / not-found responses, IG-only audit
// listing, read-only access type, fail-deny on unauth.

// ---------- Boolean helper ----------
abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

// ---------- Clinician roles (data-model.md ClinicianRole) ----------
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends Role {}

// ---------- HTTP endpoints (contracts/http-api.md) ----------
abstract sig OperationKind {}
one sig PostRecordsLookup, PostAuditSearch extends OperationKind {}

// ---------- Audit outcomes (data-model.md AccessOutcome) ----------
abstract sig Outcome {}
one sig Permitted, Denied, NotFoundOrDenied extends Outcome {}

// ---------- Authorisation basis (data-model.md AuthorisationBasis) ----------
abstract sig AuthBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthBasis {}

// ---------- HTTP response shape ----------
abstract sig ResponseShape {}
one sig OkSummary, ByteEquivNotFound, UnauthResp, ValidationErr, ServiceUnav extends ResponseShape {}

// ---------- Access type (v1: only "read") ----------
abstract sig AccessType {}
one sig ReadAccess, WriteAccess extends AccessType {}

// ---------- Permission matrix as a singleton-sig field ----------
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Domain sigs ----------
sig User { userRole: one Role }
sig Patient {}
sig CareTeam { ctClinician: one User, ctPatient: one Patient }

sig Operation {
  opKind: one OperationKind,
  authenticated: one Bool,
  caller: lone User,
  targetPatient: lone Patient,
  validated: one Bool,
  outcome: lone Outcome,
  basis: lone AuthBasis,
  contentReturned: one Bool,
  responseShape: one ResponseShape,
  pidInUrlPath: one Bool,
  summaryWellFormed: one Bool
}

sig AuditEntry {
  op: one Operation,
  clinicianSnapshot: lone User,
  roleSnapshot: lone Role,
  patientIdSnapshot: lone Patient,
  outcomeRec: lone Outcome,
  basisRec: lone AuthBasis,
  accessTypeRec: lone AccessType
}

// ---------- Non-empty universe so universal predicates are non-vacuous ----------
fact F_NonEmptyUniverse {
  some User
  some Patient
  some Operation
  some AuditEntry
  some CareTeam
}

// ---------- Permission matrix content (contracts/http-api.md) ----------
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor        -> PostRecordsLookup) +
    (Nurse         -> PostRecordsLookup) +
    (Pharmacist    -> PostRecordsLookup) +
    (ClinicalAdmin -> PostRecordsLookup) +
    (AuditOfficer  -> PostAuditSearch)
}

// ---------- Structural integrity ----------
fact F_AuthenticationConsistency {
  all op: Operation | (op.authenticated = BTrue) iff (some op.caller)
}

fact F_BasisOutcomeMapping {
  all op: Operation | (some op.outcome) iff (some op.basis)
  all op: Operation | op.outcome = Permitted         iff op.basis = CareTeamMember
  all op: Operation | op.outcome = Denied            iff op.basis = NotCareTeamMember
  all op: Operation | op.outcome = NotFoundOrDenied  iff op.basis = PatientNotFound
}

fact F_TargetPatientPresence {
  all op: Operation | op.basis = PatientNotFound implies no op.targetPatient
  all op: Operation |
    op.basis in (CareTeamMember + NotCareTeamMember) implies some op.targetPatient
}

fact F_AuditEntriesOnlyOnRecordsLookup {
  all ae: AuditEntry | some ae.op.outcome and ae.op.opKind = PostRecordsLookup
}

// ---------- Load-bearing invariants (the mutation targets) ----------

// FR-006 + permission matrix: Permitted ⇒ caller's role permitted for the op kind.
fact F_LeastPrivilegeAccess {
  all op: Operation |
    op.outcome = Permitted implies (op.caller.userRole -> op.opKind in PermMatrix.Allowed)
}

// FR-006: Permitted ⇒ a (clinician, patient) care-team-membership row exists.
fact F_CareTeamGating {
  all op: Operation |
    op.outcome = Permitted implies
      (some ct: CareTeam | ct.ctClinician = op.caller and ct.ctPatient = op.targetPatient)
}

// FR-008: every dereferenced access attempt produces an audit entry.
fact F_AuditCompletenessOnRecordsLookup {
  all op: Operation |
    (some op.outcome) implies (some ae: AuditEntry | ae.op = op)
}

// FR-010: append-only — no two audit entries point at the same operation
// (no duplicates, no mutation-as-new-row).
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry | ae1.op != ae2.op
}

// FR-009: audit-entry fields are snapshots of the recorded operation.
fact F_AttributionSnapshot {
  all ae: AuditEntry |
    ae.clinicianSnapshot = ae.op.caller
    and ae.roleSnapshot       = ae.op.caller.userRole
    and ae.patientIdSnapshot  = ae.op.targetPatient
    and ae.outcomeRec         = ae.op.outcome
    and ae.basisRec           = ae.op.basis
}

// FR-005: v1 is read-only; every audit entry's access type is Read.
fact F_ReadOnlyAccessType {
  all ae: AuditEntry | ae.accessTypeRec = ReadAccess
}

// FR-007 + SC-003: denied and not-found are byte-equivalent.
fact F_ByteEquivalentDenyAndNotFound {
  all op: Operation | op.outcome = Denied           implies op.responseShape = ByteEquivNotFound
  all op: Operation | op.outcome = NotFoundOrDenied implies op.responseShape = ByteEquivNotFound
}

// Permitted access returns a patient-summary response with content.
fact F_PermittedOkSummary {
  all op: Operation |
    op.outcome = Permitted implies (op.responseShape = OkSummary and op.contentReturned = BTrue)
}

// Content is returned ONLY on Permitted.
fact F_NoContentWhenNotPermitted {
  all op: Operation | op.contentReturned = BTrue implies op.outcome = Permitted
}

// FR-004 + SC-005: patient_id never in URL path.
fact F_NoPatientIdInUrlPath {
  all op: Operation | op.pidInUrlPath = BFalse
}

// FR-011 + SC-011: IG endpoint is hidden from non-IG roles via byte-equivalent 404.
fact F_IGEndpointHidden {
  all op: Operation |
    (op.opKind = PostAuditSearch and op.authenticated = BTrue and
     op.caller.userRole != AuditOfficer) implies op.responseShape = ByteEquivNotFound
}

// FR-001 + SC-004: unauthenticated requests get UnauthResp, no outcome,
// no content, and produce no patient-access audit entry.
fact F_AuthFailureBehaviour {
  all op: Operation |
    op.authenticated = BFalse implies (
      no op.outcome and
      op.contentReturned = BFalse and
      op.responseShape = UnauthResp and
      (no ae: AuditEntry | ae.op = op)
    )
}

// FR-013 + SC-007: SLA breach refuses access (no content, no outcome → no audit).
fact F_SLAImpliesRefusal {
  all op: Operation |
    op.responseShape = ServiceUnav implies (op.contentReturned = BFalse and no op.outcome)
}

// FR-014/FR-015 + SC-008: every record-view response is well-formed (allergies +
// warnings + identifier + DoB at the top of the payload).
fact F_OkSummaryWellFormed {
  all op: Operation | op.responseShape = OkSummary implies op.summaryWellFormed = BTrue
}

// =========================================================================
// PATTERN PREDICATES + ASSERTIONS
// =========================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation; spec.md FR-006
pred LeastPrivilege {
  some Operation
  all op: Operation |
    op.outcome = Permitted implies (op.caller.userRole -> op.opKind in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md authorisation matrix
pred PermissionCompleteness {
  // Records-lookup: allowed for the four clinical roles, denied for audit_officer.
  Doctor        -> PostRecordsLookup in PermMatrix.Allowed
  Nurse         -> PostRecordsLookup in PermMatrix.Allowed
  Pharmacist    -> PostRecordsLookup in PermMatrix.Allowed
  ClinicalAdmin -> PostRecordsLookup in PermMatrix.Allowed
  AuditOfficer  -> PostRecordsLookup not in PermMatrix.Allowed
  // Audit-search: allowed only for audit_officer.
  AuditOfficer  -> PostAuditSearch in PermMatrix.Allowed
  Doctor        -> PostAuditSearch not in PermMatrix.Allowed
  Nurse         -> PostAuditSearch not in PermMatrix.Allowed
  Pharmacist    -> PostAuditSearch not in PermMatrix.Allowed
  ClinicalAdmin -> PostAuditSearch not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, FR-008
pred AuthRequiredEverywhere {
  some Operation
  all op: Operation |
    op.authenticated = BFalse implies (
      op.contentReturned = BFalse and
      (no ae: AuditEntry | ae.op = op)
    )
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008; SC-001
pred AuditCompleteness {
  some Operation
  all op: Operation |
    (some op.outcome) implies (some ae: AuditEntry | ae.op = op)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  some AuditEntry
  all disj ae1, ae2: AuditEntry | ae1.op != ae2.op
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009 (snapshot semantics)
pred AttributionCorrectness {
  some AuditEntry
  all ae: AuditEntry |
    ae.clinicianSnapshot = ae.op.caller
    and ae.roleSnapshot       = ae.op.caller.userRole
    and ae.outcomeRec         = ae.op.outcome
    and ae.basisRec           = ae.op.basis
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006 (care-team-membership chain)
pred OwnershipBasedAccess {
  some Operation
  all op: Operation |
    op.outcome = Permitted implies
      (some ct: CareTeam | ct.ctClinician = op.caller and ct.ctPatient = op.targetPatient)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007; SC-003
pred NoInformationLeakage {
  some Operation
  all op: Operation |
    op.outcome in (Denied + NotFoundOrDenied) implies op.responseShape = ByteEquivNotFound
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// =========================================================================
// FEATURE-SPECIFIC PREDICATES (one per FR-NNN)
// =========================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 — unauthenticated rejected at boundary; no audit; no content
pred FR_001_AuthRequired {
  some Operation
  all op: Operation |
    op.authenticated = BFalse implies (
      op.responseShape = UnauthResp and
      no op.outcome and
      op.contentReturned = BFalse and
      (no ae: AuditEntry | ae.op = op)
    )
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 — authenticated requests resolve to a (clinician_id, role)
pred FR_002_RoleResolved {
  some Operation
  all op: Operation |
    op.authenticated = BTrue implies (some op.caller and some op.caller.userRole)
}
assert FR_002_RoleResolved { FR_002_RoleResolved }
check FR_002_RoleResolved for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 — UK NHS regime: per-patient queryable audit (covered by
// audit-completeness + immutability + read-by-IG-only; this predicate is a structural placeholder)
pred FR_003_NHSRegime {
  // Every audit entry is per-patient queryable: it carries a patient identifier slot.
  some AuditEntry
  all ae: AuditEntry |
    (some ae.op.targetPatient) or ae.op.basis = PatientNotFound
}
assert FR_003_NHSRegime { FR_003_NHSRegime }
check FR_003_NHSRegime for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 — patient_id never in URL path
pred FR_004_NoPidInUrl {
  some Operation
  all op: Operation | op.pidInUrlPath = BFalse
}
assert FR_004_NoPidInUrl { FR_004_NoPidInUrl }
check FR_004_NoPidInUrl for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 — v1 read-only
pred FR_005_ReadOnly {
  some AuditEntry
  all ae: AuditEntry | ae.accessTypeRec = ReadAccess
}
assert FR_005_ReadOnly { FR_005_ReadOnly }
check FR_005_ReadOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 — care-team-membership gates Permitted
pred FR_006_CareTeamGating {
  some Operation
  all op: Operation |
    op.outcome = Permitted implies
      (some ct: CareTeam | ct.ctClinician = op.caller and ct.ctPatient = op.targetPatient)
}
assert FR_006_CareTeamGating { FR_006_CareTeamGating }
check FR_006_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 — byte-equivalent denied / not-found
pred FR_007_ByteEquivalent {
  some Operation
  all op: Operation | op.outcome = Denied           implies op.responseShape = ByteEquivNotFound
  all op: Operation | op.outcome = NotFoundOrDenied implies op.responseShape = ByteEquivNotFound
}
assert FR_007_ByteEquivalent { FR_007_ByteEquivalent }
check FR_007_ByteEquivalent for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 — one audit entry per dereferenced access
pred FR_008_AuditEveryAttempt {
  some Operation
  all op: Operation |
    (some op.outcome) implies (one ae: AuditEntry | ae.op = op)
}
assert FR_008_AuditEveryAttempt { FR_008_AuditEveryAttempt }
check FR_008_AuditEveryAttempt for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 — audit fields match the operation (snapshot)
pred FR_009_AuditFieldsSnapshot {
  some AuditEntry
  all ae: AuditEntry | (
    ae.clinicianSnapshot = ae.op.caller and
    ae.roleSnapshot      = ae.op.caller.userRole and
    ae.patientIdSnapshot = ae.op.targetPatient and
    ae.outcomeRec        = ae.op.outcome and
    ae.basisRec          = ae.op.basis and
    ae.accessTypeRec     = ReadAccess
  )
}
assert FR_009_AuditFieldsSnapshot { FR_009_AuditFieldsSnapshot }
check FR_009_AuditFieldsSnapshot for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 — audit append-only / immutable
pred FR_010_AuditAppendOnly {
  some AuditEntry
  all disj ae1, ae2: AuditEntry | ae1.op != ae2.op
}
assert FR_010_AuditAppendOnly { FR_010_AuditAppendOnly }
check FR_010_AuditAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 — audit listing hidden from non-IG roles
pred FR_011_AuditByIGOnly {
  some Operation
  all op: Operation |
    (op.opKind = PostAuditSearch and op.authenticated = BTrue and
     op.caller.userRole != AuditOfficer) implies op.responseShape = ByteEquivNotFound
}
assert FR_011_AuditByIGOnly { FR_011_AuditByIGOnly }
check FR_011_AuditByIGOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 — audit retention floor (no deletion of recorded accesses)
pred FR_012_AuditRetention {
  some Operation
  all op: Operation |
    (some op.outcome) implies (some ae: AuditEntry | ae.op = op)
}
assert FR_012_AuditRetention { FR_012_AuditRetention }
check FR_012_AuditRetention for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 — 2-second SLA breach refuses access
pred FR_013_SLARefusal {
  some Operation
  all op: Operation |
    op.responseShape = ServiceUnav implies (op.contentReturned = BFalse and no op.outcome)
}
assert FR_013_SLARefusal { FR_013_SLARefusal }
check FR_013_SLARefusal for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 — allergies + key warnings at top of every record view
pred FR_014_AllergiesAtTop {
  some Operation
  all op: Operation |
    op.responseShape = OkSummary implies op.summaryWellFormed = BTrue
}
assert FR_014_AllergiesAtTop { FR_014_AllergiesAtTop }
check FR_014_AllergiesAtTop for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 — identifier + DoB at top of every record view
pred FR_015_IdDoBAtTop {
  some Operation
  all op: Operation |
    op.responseShape = OkSummary implies op.summaryWellFormed = BTrue
}
assert FR_015_IdDoBAtTop { FR_015_IdDoBAtTop }
check FR_015_IdDoBAtTop for 6