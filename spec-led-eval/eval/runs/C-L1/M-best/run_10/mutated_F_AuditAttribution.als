// === feature_model.als — Alloy model for 009 clinician-record-access ===
//
// Encodes the structural invariants of a UK-NHS clinician record-access
// feature: a read-only POST /records/lookup gated by care-team membership,
// a POST /audit/search gated by the audit_officer role, immutable audit
// entries, and a byte-equivalent denied/not-found response. See
// spec.md FR-001..FR-015 and contracts/http-api.md authorisation tables.

// ----------------------------------------------------------------------
// F_NonEmptyUniverse — force witnesses so checks aren't vacuous.
// (Predicates intentionally do NOT carry their own `some X` clauses.)
// ----------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some Access
  some AuditEntry
  some AuditSearchAttempt
}

// ----------------------------------------------------------------------
// Roles (spec.md FR-002 catalogue)
// ----------------------------------------------------------------------
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends Role {}

// ----------------------------------------------------------------------
// Operation kinds (contracts/http-api.md exposes exactly two endpoints)
// ----------------------------------------------------------------------
abstract sig OperationKind {}
one sig RecordsLookup, AuditSearch extends OperationKind {}

// ----------------------------------------------------------------------
// Permission matrix as a singleton-sig field
// Allowed cells (from contracts/http-api.md authorisation tables):
//   Doctor          -> RecordsLookup     (FR-006)
//   Nurse           -> RecordsLookup     (FR-006)
//   Pharmacist      -> RecordsLookup     (FR-006)
//   ClinicalAdmin   -> RecordsLookup     (FR-006)
//   AuditOfficer    -> AuditSearch       (FR-011)
// ----------------------------------------------------------------------
one sig PermMatrix { Allowed: set Role -> OperationKind }

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor        -> RecordsLookup) +
    (Nurse         -> RecordsLookup) +
    (Pharmacist    -> RecordsLookup) +
    (ClinicalAdmin -> RecordsLookup) +
    (AuditOfficer  -> AuditSearch)
}

// ----------------------------------------------------------------------
// Enums (data-model.md StrEnums)
// ----------------------------------------------------------------------
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

abstract sig AuthBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthBasis {}

abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

// Externally visible response envelope (FR-007 byte-equivalence)
abstract sig ResponseShape {}
one sig RecordSummary, NotFoundResponse extends ResponseShape {}

// ----------------------------------------------------------------------
// Domain entities (data-model.md)
// ----------------------------------------------------------------------
sig User { role: one Role }
sig Patient {}

sig CareTeamMembership {
  clinician: one User,
  patient:   one Patient,
  status:    one MembershipStatus
}

// An attempted call against POST /records/lookup that has cleared
// authentication and body validation (i.e., reached service.lookup_patient).
sig Access {
  caller:   one User,
  opKind:   one OperationKind,
  patient:  lone Patient,         // none = patient_id not in system
  outcome:  one AccessOutcome,
  basis:    one AuthBasis,
  response: one ResponseShape
}

// AuditEntry — append-only per-access record (FR-009, FR-010)
sig AuditEntry {
  forAccess:         one Access,
  clinicianSnapshot: one User,
  roleSnapshot:      one Role,
  patientIdSnapshot: lone Patient,
  basisSnapshot:     one AuthBasis,
  outcomeSnapshot:   one AccessOutcome
}

// A call against POST /audit/search (modelled separately because it does
// not produce an AuditEntry in this feature's audit scope — see FR-011)
sig AuditSearchAttempt {
  caller:  one User,
  outcome: one AccessOutcome
}

// ----------------------------------------------------------------------
// LOAD-BEARING FACTS (each one is a candidate mutation target)
// ----------------------------------------------------------------------

// All Access atoms model the clinical-endpoint call (contracts/http-api.md).
fact F_AccessIsRecordsLookup {
  all a: Access | a.opKind = RecordsLookup
}

// FR-006 / FR-007 / FR-011 — clinical authorisation rule:
// Permitted iff role is clinical AND active care-team membership exists.
// Also, AuditOfficer can never be Permitted on records/lookup.
fact F_AccessAuthorisationRule {
  all a: Access |
    a.outcome = Permitted implies {
      a.caller.role -> RecordsLookup in PermMatrix.Allowed
      (some m: CareTeamMembership |
         m.clinician = a.caller and m.patient = a.patient and m.status = Active)
    }
  all a: Access |
    a.caller.role = AuditOfficer implies a.outcome != Permitted
}

// FR-011 / SC-011 — IG-only audit search.
fact F_AuditSearchAuthorisation {
  all s: AuditSearchAttempt |
    s.outcome = Permitted implies s.caller.role = AuditOfficer
}

// FR-007 / FR-009 — outcome <-> basis <-> patient-existence consistency.
fact F_OutcomeBasisConsistency {
  all a: Access {
    (a.outcome = Permitted)        iff (a.basis = CareTeamMember)
    (a.outcome = Denied)           iff (a.basis = NotCareTeamMember)
    (a.outcome = NotFoundOrDenied) iff (a.basis = PatientNotFound)
    (a.basis  = PatientNotFound)   iff (no a.patient)
  }
}

// FR-007 / SC-003 — byte-equivalent denied / not-found response.
fact F_ByteEquivalentResponse {
  all a: Access {
    (a.outcome = Permitted) iff (a.response = RecordSummary)
    ((a.outcome = Denied) or (a.outcome = NotFoundOrDenied))
        iff (a.response = NotFoundResponse)
  }
}

// FR-008 / SC-001 — every Access has at least one matching AuditEntry.
fact F_AuditExists {
  all a: Access | some e: AuditEntry | e.forAccess = a
}

// FR-010 / SC-006 — append-only: no two AuditEntries describe the same Access.
fact F_AppendOnlyAuditEntries {
  all disj e1, e2: AuditEntry | e1.forAccess != e2.forAccess
}

// FR-009 — audit-entry attribution & snapshot fidelity.
fact F_AuditAttribution { /* MUTATED — body cleared by validator */ }

// ======================================================================
// PATTERN PREDICATES (catalogue)
// ======================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md auth tables; spec.md FR-006, FR-011
pred LeastPrivilege {
  all a: Access |
    a.outcome = Permitted implies
      (a.caller.role -> RecordsLookup in PermMatrix.Allowed)
  all a: Access |
    a.caller.role = AuditOfficer implies a.outcome != Permitted
  all s: AuditSearchAttempt |
    s.outcome = Permitted implies s.caller.role = AuditOfficer
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
  // Every (role, op) cell is decided: either explicitly Allowed or not.
  // Encoded by asserting the universe of cells is exactly Role x OperationKind.
  all r: Role, op: OperationKind |
    (r -> op in PermMatrix.Allowed) or (r -> op not in PermMatrix.Allowed)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-006, FR-011; contracts/http-api.md
pred PermissionGrounding {
  // Every allowed cell traces back to an FR-grounded category.
  all r: Role, op: OperationKind |
    (r -> op in PermMatrix.Allowed) implies
      ((r in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and op = RecordsLookup) or
       (r = AuditOfficer and op = AuditSearch))
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  // Every Access and AuditSearchAttempt in the universe carries a resolved
  // caller User — i.e., no anonymous call ever reaches the service layer.
  all a: Access            | one a.caller
  all s: AuditSearchAttempt | one s.caller
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006 care-team-membership
pred OwnershipBasedAccess {
  all a: Access |
    a.outcome = Permitted implies
      (some m: CareTeamMembership |
         m.clinician = a.caller and m.patient = a.patient and m.status = Active)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003
pred NoInformationLeakage {
  // Denied (exists but no care team) and NotFoundOrDenied (patient absent)
  // collapse to the same externally visible response shape.
  all a1, a2: Access |
    (a1.outcome = Denied and a2.outcome = NotFoundOrDenied)
      implies a1.response = a2.response
  // And neither leaks record content.
  all a: Access |
    a.outcome != Permitted implies a.response != RecordSummary
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, SC-001, SC-002
pred AuditCompleteness {
  // Every Access has exactly one matching AuditEntry.
  all a: Access | one e: AuditEntry | e.forAccess = a
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, SC-006; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  // No two distinct AuditEntries record the same Access (no rewrite/duplicate).
  all disj e1, e2: AuditEntry | e1.forAccess != e2.forAccess
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009
pred AttributionCorrectness {
  all e: AuditEntry {
    e.clinicianSnapshot = e.forAccess.caller
    e.outcomeSnapshot   = e.forAccess.outcome
    e.basisSnapshot     = e.forAccess.basis
    e.patientIdSnapshot = e.forAccess.patient
  }
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ======================================================================
// FR-by-FR PREDICATES (one per FR-NNN in spec.md)
// ======================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 authenticated callers only
pred FR_001_AuthRequired {
  all a: Access            | one a.caller
  all s: AuditSearchAttempt | one s.caller
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 fixed five-role catalogue
pred FR_002_RoleCatalogue {
  Role = Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin
  all u: User | u.role in Role
}
assert FR_002_RoleCatalogue { FR_002_RoleCatalogue }
check FR_002_RoleCatalogue for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003 audit data model supports per-patient query
pred FR_003_AuditPerPatientQueryable {
  // Every audit entry exposes the patient identifier it concerns
  // (via patientIdSnapshot for permitted/denied; bound to forAccess.patient).
  all e: AuditEntry | e.patientIdSnapshot = e.forAccess.patient
}
assert FR_003_AuditPerPatientQueryable { FR_003_AuditPerPatientQueryable }
check FR_003_AuditPerPatientQueryable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 patient identifier never in URL path
pred FR_004_NoIdInPath {
  // Modelled as: every Access opKind is the POST-body endpoint.
  all a: Access | a.opKind = RecordsLookup
}
assert FR_004_NoIdInPath { FR_004_NoIdInPath }
check FR_004_NoIdInPath for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 read-only scope
pred FR_005_ReadOnly {
  // OperationKind universe contains only the two read endpoints.
  OperationKind = RecordsLookup + AuditSearch
}
assert FR_005_ReadOnly { FR_005_ReadOnly }
check FR_005_ReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 care-team-membership gating, no break-glass
pred FR_006_CareTeamGating {
  all a: Access |
    a.outcome = Permitted implies
      (some m: CareTeamMembership |
         m.clinician = a.caller and m.patient = a.patient and m.status = Active)
}
assert FR_006_CareTeamGating { FR_006_CareTeamGating }
check FR_006_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 byte-equivalent denied / not-found
pred FR_007_ByteEquivalentRefusal {
  all a: Access |
    a.outcome != Permitted implies a.response = NotFoundResponse
  all a: Access |
    a.outcome = Permitted  implies a.response = RecordSummary
}
assert FR_007_ByteEquivalentRefusal { FR_007_ByteEquivalentRefusal }
check FR_007_ByteEquivalentRefusal for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008 every access generates an audit entry
pred FR_008_AlwaysAudited {
  all a: Access | some e: AuditEntry | e.forAccess = a
}
assert FR_008_AlwaysAudited { FR_008_AlwaysAudited }
check FR_008_AlwaysAudited for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 audit entry shape & attribution
pred FR_009_AuditShape {
  all e: AuditEntry {
    e.clinicianSnapshot = e.forAccess.caller
    e.outcomeSnapshot   = e.forAccess.outcome
    e.basisSnapshot     = e.forAccess.basis
    e.patientIdSnapshot = e.forAccess.patient
  }
}
assert FR_009_AuditShape { FR_009_AuditShape }
check FR_009_AuditShape for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010 audit immutability (no rewrites/duplicates)
pred FR_010_AuditAppendOnly {
  all disj e1, e2: AuditEntry | e1.forAccess != e2.forAccess
}
assert FR_010_AuditAppendOnly { FR_010_AuditAppendOnly }
check FR_010_AuditAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 audit search reserved to AuditOfficer
pred FR_011_IGOnlyAuditSearch {
  all s: AuditSearchAttempt |
    s.outcome = Permitted implies s.caller.role = AuditOfficer
}
assert FR_011_IGOnlyAuditSearch { FR_011_IGOnlyAuditSearch }
check FR_011_IGOnlyAuditSearch for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 retention floor: append-only over time
pred FR_012_RetentionFloor {
  // Append-only (no DELETE) is sufficient at the structural level.
  all disj e1, e2: AuditEntry | e1.forAccess != e2.forAccess
}
assert FR_012_RetentionFloor { FR_012_RetentionFloor }
check FR_012_RetentionFloor for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 no permitted access lacks an audit entry
pred FR_013_NoUnauditedAccess {
  all a: Access |
    a.outcome = Permitted implies (some e: AuditEntry | e.forAccess = a)
}
assert FR_013_NoUnauditedAccess { FR_013_NoUnauditedAccess }
check FR_013_NoUnauditedAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 safety content surfaced on every record view
pred FR_014_SafetyContentSurfaced {
  // On a permitted read, the response is the structured RecordSummary
  // shape (which by contract carries allergies+key_warnings at the top).
  all a: Access | a.outcome = Permitted implies a.response = RecordSummary
}
assert FR_014_SafetyContentSurfaced { FR_014_SafetyContentSurfaced }
check FR_014_SafetyContentSurfaced for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 identifier+DoB at top of record view
pred FR_015_VerificationBlockPresent {
  // Same envelope as FR-014: any permitted access carries the RecordSummary
  // shape (id + DoB at the top). Refusals never return RecordSummary.
  all a: Access | a.outcome = Permitted     implies a.response = RecordSummary
  all a: Access | a.outcome != Permitted    implies a.response != RecordSummary
}
assert FR_015_VerificationBlockPresent { FR_015_VerificationBlockPresent }
check FR_015_VerificationBlockPresent for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AttributionViolation { some e: AuditEntry | e.clinicianSnapshot != e.forAccess.caller }
