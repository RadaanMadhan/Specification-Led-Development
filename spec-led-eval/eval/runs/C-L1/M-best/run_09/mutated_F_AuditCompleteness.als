// === feature_model.als — Alloy model for Clinician Access to Patient Medical Records (009) ===
// Self-contained Alloy 6 encoding of structural invariants from
//   spec.md (FR-001 .. FR-015)
//   data-model.md (users, patients, care_team_memberships, audit_entries)
//   contracts/http-api.md (POST /records/lookup, POST /audit/search; auth + byte-equivalent 404)

// ---------- Roles & operation kinds ----------

abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, AuditOfficer extends Role {}

abstract sig OperationKind {}
one sig RecordsLookup, AuditSearch extends OperationKind {}

// ---------- Outcome & authorisation-basis enums ----------

abstract sig Outcome {}
one sig Permitted, Denied, NotFoundOrDenied extends Outcome {}

abstract sig AuthBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthBasis {}

// ---------- Externally-visible response shape (used for byte-equivalence reasoning) ----------

abstract sig Response {}
one sig SummaryResponse, NotFoundResponse, AuditListResponse, UnauthResponse extends Response {}

// ---------- Boolean helper ----------

abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

// ---------- Permission matrix as a singleton-sig field (contracts/http-api.md) ----------

one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Dynamic sigs ----------

sig User { role: one Role }
sig Patient {}

sig CareTeamMembership {
  clinician: one User,
  patient: one Patient,
  membershipActive: one Bool
}

sig Operation {
  caller: one User,
  kind: one OperationKind,
  authenticated: one Bool,
  targetPatient: lone Patient,
  outcome: lone Outcome,
  basis: lone AuthBasis,
  response: one Response
}

sig AuditEntry {
  op: one Operation,
  loggedClinician: one User,
  loggedRoleSnapshot: one Role,
  loggedPatient: one Patient,
  loggedOutcome: one Outcome,
  loggedBasis: one AuthBasis
}

// ---------- Non-empty universe (so predicates can bite under default scope) ----------

fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some Operation
  some AuditEntry
}

// ---------- Permission matrix definition (contracts/http-api.md authorisation sections) ----------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor -> RecordsLookup) +
    (Nurse -> RecordsLookup) +
    (Pharmacist -> RecordsLookup) +
    (ClinicalAdmin -> RecordsLookup) +
    (AuditOfficer -> AuditSearch)
}

// ---------- Operation well-formedness (data-model.md AccessOutcome / AuthBasis enums) ----------

fact F_OperationWellFormed {
  // AuditSearch operations never carry the clinical outcome / basis / target-patient triple
  all o: Operation |
    o.kind = AuditSearch implies (no o.outcome and no o.basis and no o.targetPatient)
  // Authenticated RecordsLookup operations always carry the triple
  all o: Operation |
    (o.kind = RecordsLookup and o.authenticated = BTrue) implies
      (one o.outcome and one o.basis and one o.targetPatient)
}

// ---------- Outcome <-> basis consistency (data-model.md table) ----------

fact F_OutcomeBasisConsistency {
  all o: Operation | o.outcome = Permitted          implies o.basis = CareTeamMember
  all o: Operation | o.outcome = Denied             implies o.basis = NotCareTeamMember
  all o: Operation | o.outcome = NotFoundOrDenied   implies o.basis = PatientNotFound
}

// ---------- Care-team-membership gating (FR-006) ----------

fact F_CareTeamGated {
  all o: Operation |
    (o.kind = RecordsLookup and o.outcome = Permitted) implies
      (some m: CareTeamMembership |
        m.clinician = o.caller and
        m.patient = o.targetPatient and
        m.membershipActive = BTrue)
}

// ---------- Authentication boundary (FR-001) ----------

fact F_AuthRequired {
  // Unauthenticated requests never produce a record-summary or audit-list response
  all o: Operation |
    o.authenticated = BFalse implies
      (o.response != SummaryResponse and o.response != AuditListResponse)
  // Unauthenticated requests never produce an audit entry (audit lives in host IdP)
  no a: AuditEntry | a.op.authenticated = BFalse
  // Unauthenticated requests never reach the dereference/outcome stage
  all o: Operation |
    o.authenticated = BFalse implies (no o.outcome and no o.basis and no o.targetPatient)
}

// ---------- Audit completeness (FR-008, FR-013, SC-001/SC-002) ----------

fact F_AuditCompleteness { /* MUTATED — body cleared by validator */ }

// ---------- Audit attribution & snapshot correctness (FR-009) ----------

fact F_AuditAttribution {
  all a: AuditEntry |
    a.loggedClinician = a.op.caller and
    a.loggedRoleSnapshot = a.op.caller.role and
    a.loggedPatient = a.op.targetPatient and
    a.loggedOutcome = a.op.outcome and
    a.loggedBasis = a.op.basis
}

// ---------- Audit append-only (FR-010, FR-012) ----------

fact F_AppendOnlyAudit {
  // At most one audit entry per Operation -- no second "amended" version
  all o: Operation | lone a: AuditEntry | a.op = o
}

// ---------- Least privilege (FR-006, FR-011; contracts permission tables) ----------

fact F_LeastPrivilege {
  all o: Operation |
    o.outcome = Permitted implies (o.caller.role -> o.kind) in PermMatrix.Allowed
  all o: Operation |
    o.response = AuditListResponse implies (o.caller.role -> o.kind) in PermMatrix.Allowed
}

// ---------- Response-shape / byte-equivalence (FR-007, FR-011, SC-003, SC-011) ----------

fact F_ResponseShape {
  all o: Operation |
    (o.kind = RecordsLookup and o.outcome = Permitted) implies o.response = SummaryResponse
  all o: Operation |
    (o.kind = RecordsLookup and (o.outcome = Denied or o.outcome = NotFoundOrDenied))
      implies o.response = NotFoundResponse
  all o: Operation |
    (o.kind = AuditSearch and o.authenticated = BTrue and o.caller.role != AuditOfficer)
      implies o.response = NotFoundResponse
  all o: Operation |
    o.response = SummaryResponse implies (o.kind = RecordsLookup and o.outcome = Permitted)
  all o: Operation |
    o.response = AuditListResponse implies (o.kind = AuditSearch and o.caller.role = AuditOfficer)
}

// ============================================================================
// Predicates & assertions — patterns from the catalogue
// ============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation; spec.md FR-006, FR-011
pred LeastPrivilege {
  all o: Operation |
    o.outcome = Permitted implies (o.caller.role -> o.kind) in PermMatrix.Allowed
  all o: Operation |
    o.response = AuditListResponse implies (o.caller.role -> o.kind) in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables
pred PermissionCompleteness {
  // Every (Role x OperationKind) cell has a defined verdict via the closed-world matrix.
  all r: Role, k: OperationKind |
    (r -> k in PermMatrix.Allowed) or (r -> k not in PermMatrix.Allowed)
  // Matrix is non-empty (at least one allow) and not universal (at least one deny).
  some PermMatrix.Allowed
  some r: Role, k: OperationKind | r -> k not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  all o: Operation |
    o.authenticated = BFalse implies
      (o.response != SummaryResponse and o.response != AuditListResponse)
  no a: AuditEntry | a.op.authenticated = BFalse
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, FR-009; SC-001, SC-002
pred AuditCompleteness {
  all o: Operation |
    (o.kind = RecordsLookup and o.authenticated = BTrue) implies
      (one a: AuditEntry | a.op = o)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, FR-012; data-model.md no UPDATE/DELETE
pred AppendOnly {
  // No two audit entries for the same Operation -- no amended/replaced versions
  all o: Operation | lone a: AuditEntry | a.op = o
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md audit_entries snapshots
pred AttributionCorrectness {
  all a: AuditEntry |
    a.loggedClinician = a.op.caller and
    a.loggedRoleSnapshot = a.op.caller.role and
    a.loggedPatient = a.op.targetPatient and
    a.loggedOutcome = a.op.outcome and
    a.loggedBasis = a.op.basis
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md care_team_memberships
pred OwnershipBasedAccess {
  all o: Operation |
    (o.kind = RecordsLookup and o.outcome = Permitted) implies
      (some m: CareTeamMembership |
        m.clinician = o.caller and
        m.patient = o.targetPatient and
        m.membershipActive = BTrue)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003, SC-011
pred NoInformationLeakage {
  // Denied and not-found-or-denied collapse to the same NotFoundResponse on the wire
  all o: Operation |
    (o.outcome = Denied or o.outcome = NotFoundOrDenied) implies o.response = NotFoundResponse
  // Non-IG callers on the IG endpoint also collapse to NotFoundResponse (not 403)
  all o: Operation |
    (o.kind = AuditSearch and o.authenticated = BTrue and o.caller.role != AuditOfficer)
      implies o.response = NotFoundResponse
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// ============================================================================
// Feature-specific predicates — one per FR-NNN in spec.md
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication required, no audit on auth failure
pred FR_001_AuthRequired {
  all o: Operation |
    o.authenticated = BFalse implies
      (o.response != SummaryResponse and o.response != AuditListResponse)
  no a: AuditEntry | a.op.authenticated = BFalse
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 host-supplied identity & v1 role catalogue
pred FR_002_RoleFromHost {
  all u: User | one u.role
  all u: User | u.role in (Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin)
}
assert FR_002_RoleFromHost { FR_002_RoleFromHost }
check FR_002_RoleFromHost for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 audit data model is per-patient queryable
pred FR_003_AuditPerPatientQueryable {
  // Each audit entry is anchored to exactly one patient identifier (enables per-patient query)
  all a: AuditEntry | one a.loggedPatient
}
assert FR_003_AuditPerPatientQueryable { FR_003_AuditPerPatientQueryable }
check FR_003_AuditPerPatientQueryable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 patient_id not in URL paths (modelled: kinds are POST-bodied)
pred FR_004_NoPatientIdInURL {
  // The OperationKind enumeration captures the URL path; patient identity flows via targetPatient
  OperationKind = RecordsLookup + AuditSearch
  all o: Operation | o.kind in (RecordsLookup + AuditSearch)
}
assert FR_004_NoPatientIdInURL { FR_004_NoPatientIdInURL }
check FR_004_NoPatientIdInURL for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 read-only access (no write/amend/prescribe kinds in v1)
pred FR_005_ReadOnly {
  // Closed-world OperationKind = exactly the two read endpoints
  OperationKind = RecordsLookup + AuditSearch
  // No audit entry refers to an op that isn't a read-style endpoint
  all a: AuditEntry | a.op.kind in (RecordsLookup + AuditSearch)
}
assert FR_005_ReadOnly { FR_005_ReadOnly }
check FR_005_ReadOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 care-team-membership authorisation rule
pred FR_006_CareTeamGated {
  all o: Operation |
    o.outcome = Permitted implies
      (some m: CareTeamMembership |
        m.clinician = o.caller and
        m.patient = o.targetPatient and
        m.membershipActive = BTrue)
}
assert FR_006_CareTeamGated { FR_006_CareTeamGated }
check FR_006_CareTeamGated for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 byte-equivalent denied / not-found
pred FR_007_ByteEquivalentDenial {
  all o: Operation |
    (o.outcome = Denied or o.outcome = NotFoundOrDenied) implies o.response = NotFoundResponse
}
assert FR_007_ByteEquivalentDenial { FR_007_ByteEquivalentDenial }
check FR_007_ByteEquivalentDenial for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 always-on audit on the clinical endpoint
pred FR_008_AlwaysAudit {
  all o: Operation |
    (o.kind = RecordsLookup and o.authenticated = BTrue) implies
      (one a: AuditEntry | a.op = o)
}
assert FR_008_AlwaysAudit { FR_008_AlwaysAudit }
check FR_008_AlwaysAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 audit entries snapshot clinician identity, outcome, basis
pred FR_009_AuditFieldsSnapshot {
  all a: AuditEntry |
    a.loggedClinician = a.op.caller and
    a.loggedRoleSnapshot = a.op.caller.role and
    a.loggedOutcome = a.op.outcome and
    a.loggedBasis = a.op.basis and
    a.loggedPatient = a.op.targetPatient
}
assert FR_009_AuditFieldsSnapshot { FR_009_AuditFieldsSnapshot }
check FR_009_AuditFieldsSnapshot for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 audit immutability
pred FR_010_AuditImmutable {
  // No operation has two audit entries -- no UPDATE materialised as a second row
  all o: Operation | lone a: AuditEntry | a.op = o
}
assert FR_010_AuditImmutable { FR_010_AuditImmutable }
check FR_010_AuditImmutable for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 audit listing is IG-only; existence hidden from clinicians
pred FR_011_AuditByIGOnly {
  all o: Operation |
    o.response = AuditListResponse implies (o.kind = AuditSearch and o.caller.role = AuditOfficer)
  all o: Operation |
    (o.kind = AuditSearch and o.authenticated = BTrue and o.caller.role != AuditOfficer)
      implies o.response = NotFoundResponse
}
assert FR_011_AuditByIGOnly { FR_011_AuditByIGOnly }
check FR_011_AuditByIGOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 8-year retention floor enforced by absence of DELETE path
pred FR_012_NoDeletePath {
  // Every authenticated RecordsLookup still has its audit entry (audit is never removed)
  all o: Operation |
    (o.kind = RecordsLookup and o.authenticated = BTrue) implies
      (some a: AuditEntry | a.op = o)
}
assert FR_012_NoDeletePath { FR_012_NoDeletePath }
check FR_012_NoDeletePath for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 2-second audit SLA -- no record observation without audit
pred FR_013_NoRecordWithoutAudit {
  // No clinician observes a SummaryResponse without a matching AuditEntry
  all o: Operation |
    o.response = SummaryResponse implies (one a: AuditEntry | a.op = o)
}
assert FR_013_NoRecordWithoutAudit { FR_013_NoRecordWithoutAudit }
check FR_013_NoRecordWithoutAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 allergies/key warnings at top -- modelled as fixed response shape
pred FR_014_SafetyAtTop {
  // The permitted-read response shape is the single canonical SummaryResponse atom.
  all o: Operation | o.outcome = Permitted implies o.response = SummaryResponse
}
assert FR_014_SafetyAtTop { FR_014_SafetyAtTop }
check FR_014_SafetyAtTop for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 identifier + DoB at top -- same fixed-shape encoding
pred FR_015_IdentifierAtTop {
  all o: Operation | o.outcome = Permitted implies o.response = SummaryResponse
}
assert FR_015_IdentifierAtTop { FR_015_IdentifierAtTop }
check FR_015_IdentifierAtTop for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AuditCompletenessViolation { some o: Operation | o.kind = RecordsLookup and o.authenticated = BTrue and (no a: AuditEntry | a.op = o) }
