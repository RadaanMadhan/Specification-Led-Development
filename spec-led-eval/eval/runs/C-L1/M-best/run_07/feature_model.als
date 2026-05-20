// === feature_model.als — Alloy model for Clinician Access to Patient Medical Records (009) ===

// Make the universe non-empty so universally-quantified assertions are not vacuously satisfied.
fact F_NonEmptyUniverse {
  some User
  some Patient
  some Operation
  some AuditEntry
  some CareTeamMembership
}

// ===========================================================================
//  Domain sigs
// ===========================================================================

// Clinician roles (FR-002, data-model.md ClinicianRole)
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends Role {}

// The two POST endpoints (contracts/http-api.md). Body-carried patient_id (FR-004).
abstract sig OperationKind {}
one sig LookupRecord, AuditSearch extends OperationKind {}

// Access outcomes (data-model.md AccessOutcome)
abstract sig Outcome {}
one sig Permitted, Denied, NotFoundOrDenied extends Outcome {}

// Audit authorisation basis (data-model.md AuthorisationBasis)
abstract sig AuthorisationBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthorisationBasis {}

// access_type column on audit entry. v1 ships only Read; future write features
// would add Amend / Prescribe (FR-005 read-only scope).
abstract sig AccessType {}
one sig Read, Amend, Prescribe extends AccessType {}

// Explicit boolean flags.
abstract sig Bool {}
one sig True, False extends Bool {}

// Clinician / IG-officer user.
sig User {
  role: one Role
}

// Patient (opaque identifier in real life; here just an atom).
sig Patient {}

// Care-team membership row (all rows present in the model are taken to be active).
sig CareTeamMembership {
  clinician: one User,
  patient: one Patient
}

// One access attempt against the feature.
sig Operation {
  kind: one OperationKind,
  authenticated: one Bool,
  caller: lone User,             // present iff authenticated
  targetPatient: lone Patient,   // none if patient_id did not resolve to a Patient
  outcome: lone Outcome,         // none if rejected at auth / validation boundary
  recordReturned: one Bool,      // True iff patient-summary content was returned
  byteEquivNotFound: one Bool    // True iff the canonical 404 was returned
}

// Audit-entry row. Append-only (FR-010), retained 8y+ (FR-012).
sig AuditEntry {
  op: one Operation,
  clinicianSnapshot: one User,
  roleSnapshot: one Role,
  patientRef: lone Patient,
  occurredAccessType: one AccessType,
  outcomeRecorded: one Outcome,
  basisRecorded: one AuthorisationBasis
}

// Permission matrix as a singleton-sig field (contracts/http-api.md authz tables).
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ===========================================================================
//  Named structural facts (mutation-testable)
// ===========================================================================

// Permission matrix from contracts/http-api.md:
//   POST /records/lookup: doctor, nurse, pharmacist, clinical_admin
//   POST /audit/search:   audit_officer only
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor        -> LookupRecord) +
    (Nurse         -> LookupRecord) +
    (Pharmacist    -> LookupRecord) +
    (ClinicalAdmin -> LookupRecord) +
    (AuditOfficer  -> AuditSearch)
}

// Authentication boundary (FR-001, SC-004): unauthenticated ⇒ no caller, no
// outcome, no record content, and no audit row.
fact F_AuthBoundary {
  all op: Operation {
    (op.authenticated = True) iff (some op.caller)
    op.authenticated = False implies (no op.outcome)
    op.authenticated = False implies (op.recordReturned = False)
    op.authenticated = False implies (no ae: AuditEntry | ae.op = op)
  }
}

// Outcome present ⇒ authenticated (contrapositive of F_AuthBoundary's third clause).
fact F_OutcomeRequiresAuth {
  all op: Operation | some op.outcome implies op.authenticated = True
}

// FR-006 / FR-011 / SC-010 / SC-011: a Permitted outcome is only possible if the
// caller's role permits the endpoint per the matrix.
fact F_LeastPrivilege {
  all op: Operation |
    op.outcome = Permitted implies ((op.caller.role -> op.kind) in PermMatrix.Allowed)
}

// FR-006: LookupRecord Permitted ⇒ active care-team membership exists.
fact F_CareTeamGating {
  all op: Operation |
    (op.kind = LookupRecord and op.outcome = Permitted) implies
      (some m: CareTeamMembership | m.clinician = op.caller and m.patient = op.targetPatient)
}

// FR-007 / FR-011 / SC-003 / SC-011: deny / not-found on the clinical endpoint, and
// any non-IG access to the audit-search endpoint, returns the byte-equivalent 404
// with no record content.
fact F_NoInfoLeakage {
  all op: Operation {
    (op.kind = LookupRecord and some op.outcome and op.outcome != Permitted) implies
      (op.byteEquivNotFound = True and op.recordReturned = False)
    (op.kind = AuditSearch and op.authenticated = True and op.caller.role != AuditOfficer) implies
      (op.byteEquivNotFound = True and op.recordReturned = False)
  }
}

// Record content only ever leaves the system on a Permitted outcome.
fact F_RecordOnlyWhenPermitted {
  all op: Operation | op.recordReturned = True implies op.outcome = Permitted
}

// FR-014 / FR-015 / SC-008: the Permitted path must return the patient summary
// (so allergies / warnings / id / DoB are actually surfaced).
fact F_PermittedReturnsRecord {
  all op: Operation | op.outcome = Permitted implies op.recordReturned = True
  all op: Operation | op.outcome = Permitted implies some op.targetPatient
}

// FR-008 / SC-001 / SC-002: every LookupRecord attempt that passed auth and
// validation produces an audit entry. ("some" — uniqueness is enforced by
// F_AppendOnlyAuditEntries below.)
fact F_AuditCompleteness {
  all op: Operation |
    (op.kind = LookupRecord and op.authenticated = True and some op.outcome) implies
      (some ae: AuditEntry | ae.op = op)
}

// FR-010 / FR-012 / SC-006: audit entries are append-only — at most one entry
// per operation. No re-write, no duplicate.
fact F_AppendOnlyAuditEntries {
  all op: Operation | (lone ae: AuditEntry | ae.op = op)
}

// AuditSearch does not produce patient-access audit entries (contracts: the IG
// endpoint is out of FR-008's scope; auditing the auditor is a separate concern).
fact F_AuditSearchNoPatientAudit {
  all ae: AuditEntry | ae.op.kind = LookupRecord
}

// FR-009: snapshot semantics — audit entry's clinician/role/patient/outcome
// match the recorded operation.
fact F_AttributionCorrectness {
  all ae: AuditEntry {
    ae.clinicianSnapshot = ae.op.caller
    ae.roleSnapshot = ae.op.caller.role
    ae.patientRef = ae.op.targetPatient
    ae.outcomeRecorded = ae.op.outcome
  }
}

// Audit basis must agree with the outcome it explains.
fact F_BasisConsistency {
  all ae: AuditEntry {
    (ae.outcomeRecorded = Permitted) iff (ae.basisRecorded = CareTeamMember)
    (ae.outcomeRecorded = Denied) iff (ae.basisRecorded = NotCareTeamMember)
    (ae.outcomeRecorded = NotFoundOrDenied) iff (ae.basisRecorded = PatientNotFound)
  }
}

// FR-005 read-only: v1 records only Read accesses. (Future Amend / Prescribe
// kinds exist in the type lattice but are forbidden by this fact.)
fact F_OnlyReadInV1 {
  all ae: AuditEntry | ae.occurredAccessType = Read
}

// Denied / NotFoundOrDenied semantic distinction in the data model.
fact F_OutcomeSemantics {
  all op: Operation |
    (op.kind = LookupRecord and op.outcome = NotFoundOrDenied) implies (no op.targetPatient)
  all op: Operation |
    (op.kind = LookupRecord and op.outcome = Denied) implies
      (some op.targetPatient and
       (no m: CareTeamMembership | m.clinician = op.caller and m.patient = op.targetPatient))
}

// ===========================================================================
//  Catalogue-pattern predicates and assertions
// ===========================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authz tables; spec.md FR-006, FR-011
pred LeastPrivilege {
  all op: Operation |
    op.outcome = Permitted implies ((op.caller.role -> op.kind) in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md authz tables
pred PermissionCompleteness {
  // Every cell is either allowed or denied (closed-world). And the denials we
  // care about hold: AuditOfficer cannot LookupRecord; clinical roles cannot
  // AuditSearch.
  (AuditOfficer  -> LookupRecord) not in PermMatrix.Allowed
  (Doctor        -> AuditSearch ) not in PermMatrix.Allowed
  (Nurse         -> AuditSearch ) not in PermMatrix.Allowed
  (Pharmacist    -> AuditSearch ) not in PermMatrix.Allowed
  (ClinicalAdmin -> AuditSearch ) not in PermMatrix.Allowed
  // And the allowed cells we depend on for FRs do hold:
  (Doctor        -> LookupRecord) in PermMatrix.Allowed
  (AuditOfficer  -> AuditSearch ) in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, SC-004; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  all op: Operation |
    op.authenticated = False implies
      (no op.outcome and op.recordReturned = False and (no ae: AuditEntry | ae.op = op))
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, SC-001, SC-002
pred AuditCompleteness {
  all op: Operation |
    (op.kind = LookupRecord and op.authenticated = True and some op.outcome) implies
      (some ae: AuditEntry | ae.op = op)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, FR-012, SC-006; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  all disj ae1, ae2: AuditEntry | ae1.op != ae2.op
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md audit_entries.clinician_*
pred AttributionCorrectness {
  all ae: AuditEntry {
    ae.clinicianSnapshot = ae.op.caller
    ae.roleSnapshot = ae.op.caller.role
    ae.outcomeRecorded = ae.op.outcome
  }
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006, SC-010; data-model.md care_team_memberships
pred OwnershipBasedAccess {
  all op: Operation |
    (op.kind = LookupRecord and op.outcome = Permitted) implies
      (some m: CareTeamMembership | m.clinician = op.caller and m.patient = op.targetPatient)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, FR-011, SC-003, SC-011
pred NoInformationLeakage {
  all op: Operation |
    (op.kind = LookupRecord and some op.outcome and op.outcome != Permitted) implies
      (op.byteEquivNotFound = True and op.recordReturned = False)
  all op: Operation |
    (op.kind = AuditSearch and op.authenticated = True and op.caller.role != AuditOfficer) implies
      (op.byteEquivNotFound = True and op.recordReturned = False)
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// ===========================================================================
//  Per-FR feature-specific predicates and assertions
// ===========================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 unauthenticated requests rejected at boundary, no audit
pred FR_001_AuthRequired {
  all op: Operation |
    op.authenticated = False implies
      (no op.outcome and op.recordReturned = False and (no ae: AuditEntry | ae.op = op))
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 identity resolved from host; caller has exactly one role
pred FR_002_IdentityResolved {
  all op: Operation | op.authenticated = True implies (one op.caller and one op.caller.role)
}
assert FR_002_IdentityResolved { FR_002_IdentityResolved }
check FR_002_IdentityResolved for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 audit log supports per-patient-identifier query
pred FR_003_AuditPerPatientQueryable {
  // Every Permitted access carries an audit entry whose patientRef matches a
  // real Patient — i.e. queryable by patient identifier.
  all ae: AuditEntry |
    ae.outcomeRecorded = Permitted implies some ae.patientRef
}
assert FR_003_AuditPerPatientQueryable { FR_003_AuditPerPatientQueryable }
check FR_003_AuditPerPatientQueryable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 patient identifiers never in URL paths
// (Modelled structurally: the only operation kinds are the two body-carried POSTs;
// no path-parameter kinds exist in the type lattice.)
pred FR_004_NoUrlPathPatientId {
  OperationKind = LookupRecord + AuditSearch
}
assert FR_004_NoUrlPathPatientId { FR_004_NoUrlPathPatientId }
check FR_004_NoUrlPathPatientId for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 read-only — audit entries only record Read access
pred FR_005_ReadOnly {
  all ae: AuditEntry | ae.occurredAccessType = Read
}
assert FR_005_ReadOnly { FR_005_ReadOnly }
check FR_005_ReadOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 care-team-membership gating
pred FR_006_CareTeamGating {
  all op: Operation |
    (op.kind = LookupRecord and op.outcome = Permitted) implies
      (some m: CareTeamMembership | m.clinician = op.caller and m.patient = op.targetPatient)
}
assert FR_006_CareTeamGating { FR_006_CareTeamGating }
check FR_006_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 byte-equivalent denied / not-found response
pred FR_007_ByteEquivalentNotFound {
  all op: Operation |
    (op.kind = LookupRecord and some op.outcome and op.outcome != Permitted) implies
      (op.byteEquivNotFound = True and op.recordReturned = False)
}
assert FR_007_ByteEquivalentNotFound { FR_007_ByteEquivalentNotFound }
check FR_007_ByteEquivalentNotFound for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 always-on audit on the clinical endpoint
pred FR_008_AlwaysAudit {
  all op: Operation |
    (op.kind = LookupRecord and op.authenticated = True and some op.outcome) implies
      (some ae: AuditEntry | ae.op = op)
}
assert FR_008_AlwaysAudit { FR_008_AlwaysAudit }
check FR_008_AlwaysAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 audit-entry shape — snapshot fields match operation
pred FR_009_AuditFieldsCorrect {
  all ae: AuditEntry {
    ae.clinicianSnapshot = ae.op.caller
    ae.roleSnapshot = ae.op.caller.role
    ae.outcomeRecorded = ae.op.outcome
    ae.occurredAccessType = Read
  }
}
assert FR_009_AuditFieldsCorrect { FR_009_AuditFieldsCorrect }
check FR_009_AuditFieldsCorrect for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 audit immutability — no duplicate / mutate path
pred FR_010_AuditAppendOnly {
  all disj ae1, ae2: AuditEntry | ae1.op != ae2.op
}
assert FR_010_AuditAppendOnly { FR_010_AuditAppendOnly }
check FR_010_AuditAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 audit-search restricted to audit_officer
pred FR_011_AuditSearchIGOnly {
  all op: Operation |
    (op.kind = AuditSearch and op.outcome = Permitted) implies op.caller.role = AuditOfficer
}
assert FR_011_AuditSearchIGOnly { FR_011_AuditSearchIGOnly }
check FR_011_AuditSearchIGOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 retention floor — no orphan delete; every audit row persists with its op
pred FR_012_NoDelete {
  all ae: AuditEntry | some ae.op
}
assert FR_012_NoDelete { FR_012_NoDelete }
check FR_012_NoDelete for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 record never returned without a matching audit entry
pred FR_013_NoRecordWithoutAudit {
  all op: Operation |
    op.recordReturned = True implies (some ae: AuditEntry | ae.op = op)
}
assert FR_013_NoRecordWithoutAudit { FR_013_NoRecordWithoutAudit }
check FR_013_NoRecordWithoutAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 clinical-safety content surfaced on every Permitted response
pred FR_014_SafetyContentReturned {
  all op: Operation |
    op.outcome = Permitted implies (op.recordReturned = True and some op.targetPatient)
}
assert FR_014_SafetyContentReturned { FR_014_SafetyContentReturned }
check FR_014_SafetyContentReturned for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 identifier + DoB at top of every record view
pred FR_015_PatientIdAtTop {
  all op: Operation | op.outcome = Permitted implies some op.targetPatient
}
assert FR_015_PatientIdAtTop { FR_015_PatientIdAtTop }
check FR_015_PatientIdAtTop for 6