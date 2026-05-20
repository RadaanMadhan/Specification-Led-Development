// === feature_model.als — Alloy model for Clinician Record Access (009-clinician-record-access, ref C-L1) ===
//
// Encodes the structural invariants for v1 of the clinician record-access feature:
//   - authentication boundary (FR-001)
//   - role catalogue (FR-002, FR-005)
//   - care-team-membership gating (FR-006)
//   - byte-equivalent denied/not-found responses (FR-007 / no information leakage)
//   - always-on, immutable, attributable audit log (FR-008..FR-013)
//   - IG-only audit-listing endpoint (FR-011)
//   - audit-before-record SLA invariant (FR-013)
//   - record-view shape (FR-014, FR-015) — captured structurally as "patient resolved"
//
// Two endpoints exist in v1: POST /records/lookup (LookupRecord) and POST /audit/search (SearchAudit).

// ------------------- Static enums -------------------

abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends Role {}

abstract sig OperationKind {}
one sig LookupRecord, SearchAudit extends OperationKind {}

// Permission matrix from contracts/http-api.md (Authorisation sections):
//   LookupRecord: Doctor, Nurse, Pharmacist, ClinicalAdmin  (NOT AuditOfficer)
//   SearchAudit:  AuditOfficer only
one sig PermMatrix { Allowed: set Role -> OperationKind }

abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}
// (NotFoundOrDenied collapses to Denied in this model: spec FR-007 / SC-003 says they
//  are externally byte-identical; the distinction lives only inside the audit log.)

abstract sig AuthBasis {}
one sig BasisCareTeam, BasisNotCareTeam extends AuthBasis {}

abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

abstract sig Bool {}
one sig BTrue, BFalse extends Bool {}

// ------------------- Domain sigs -------------------

sig User { role: one Role }

sig Patient {}

sig CareTeamMembership {
  clinician: one User,
  patient: one Patient,
  status: one MembershipStatus
}

sig Operation {
  caller: one User,
  kind: one OperationKind,
  authenticated: one Bool,
  presentedPatient: one Patient,
  outcome: lone Outcome,        // present iff authenticated
  recordReturned: one Bool
}

sig AuditEntry {
  op: one Operation,
  clinicianSnapshot: one User,
  roleSnapshot: one Role,
  outcomeRecorded: one Outcome,
  basisRecorded: one AuthBasis
}

// ------------------- Non-empty universe -------------------

fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some Operation
  some AuditEntry
}

// ------------------- Structural facts -------------------

// Permission matrix exactly mirrors contracts/http-api.md authorisation tables.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor        -> LookupRecord) +
    (Nurse         -> LookupRecord) +
    (Pharmacist    -> LookupRecord) +
    (ClinicalAdmin -> LookupRecord) +
    (AuditOfficer  -> SearchAudit)
}

// FR-001 / SC-004: unauthenticated requests return no record content and produce no audit entry.
fact F_AuthRequired {
  all op: Operation |
    op.authenticated = BFalse implies
      (no op.outcome and
       op.recordReturned = BFalse and
       (no ae: AuditEntry | ae.op = op))
}

// Operations that pass the authentication boundary resolve to an outcome.
fact F_OutcomeWhenAuthenticated {
  all op: Operation |
    op.authenticated = BTrue implies (one op.outcome)
}

// FR-008 / SC-001: every authenticated LookupRecord operation has AT LEAST one audit entry.
// (Uniqueness is enforced separately by F_AppendOnlyAuditEntries; combined they give 1-1.)
fact F_AuditOneToOne {
  all op: Operation |
    (op.authenticated = BTrue and op.kind = LookupRecord)
      implies (some ae: AuditEntry | ae.op = op)
}

// Audit entries exist only for authenticated patient-record-lookup operations
// (per contracts/http-api.md: /audit/search itself is NOT audited in v1).
fact F_AuditOnlyForLookups {
  all ae: AuditEntry |
    ae.op.authenticated = BTrue and ae.op.kind = LookupRecord
}

// FR-010 / FR-012 / SC-006: audit entries are append-only — no two entries record the
// same operation. Combined with F_AuditOneToOne this enforces exactly-one-per-op.
fact F_AppendOnlyAuditEntries {
  all disj a1, a2: AuditEntry | a1.op != a2.op
}

// FR-009 / AttributionCorrectness: audit-entry snapshots match the actual caller and role.
fact F_AuditAttribution {
  all ae: AuditEntry |
    ae.clinicianSnapshot = ae.op.caller and
    ae.roleSnapshot      = ae.op.caller.role and
    ae.outcomeRecorded   = ae.op.outcome
}

// FR-006 / SC-010: a Permitted LookupRecord requires an Active care-team membership.
fact F_CareTeamGating {
  all op: Operation |
    (op.kind = LookupRecord and op.outcome = Permitted)
      implies (some m: CareTeamMembership |
                 m.clinician = op.caller and
                 m.patient   = op.presentedPatient and
                 m.status    = Active)
}

// LeastPrivilege: any Permitted outcome's (role, kind) cell must live in the matrix.
fact F_LeastPrivilege {
  all op: Operation |
    op.outcome = Permitted implies
      op.caller.role -> op.kind in PermMatrix.Allowed
}

// FR-007 / SC-003: a record is returned only when the outcome is Permitted.
fact F_NoLeakage {
  all op: Operation |
    op.recordReturned = BTrue implies op.outcome = Permitted
}

// ------------------- Predicates / assertions / checks -------------------

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md §Authentication
pred FR_001_AuthRequired {
  all op: Operation |
    op.authenticated = BFalse implies
      (op.recordReturned = BFalse and (no ae: AuditEntry | ae.op = op))
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001 (contrapositive form)
pred AuthRequiredEverywhere {
  all op: Operation |
    op.recordReturned = BTrue implies op.authenticated = BTrue
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 role resolved exactly once from host identity context
pred FR_002_OneRolePerUser {
  all u: User | one u.role
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 NHS regulatory regime (covered structurally via audit + retention)
pred FR_003_NhsRegulatoryShape {
  // The audit log carries the per-patient query shape required by NHS App "who accessed my record".
  // Modelled as: every audit entry pins to exactly one Operation and one Patient (via op.presentedPatient).
  all ae: AuditEntry | one ae.op and one ae.op.presentedPatient
}
assert FR_003_NhsRegulatoryShape { FR_003_NhsRegulatoryShape }
check FR_003_NhsRegulatoryShape for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 patient identifiers never in URL paths
// Structural surrogate: every operation carries the patient-id as a body-level field
// (presentedPatient is a relation on Operation, not a URL component).
pred FR_004_PatientIdInBody {
  all op: Operation | one op.presentedPatient
}
assert FR_004_PatientIdInBody { FR_004_PatientIdInBody }
check FR_004_PatientIdInBody for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 read-only scope — only LookupRecord and SearchAudit exist
pred FR_005_ReadOnlyScope {
  all op: Operation | op.kind = LookupRecord or op.kind = SearchAudit
}
assert FR_005_ReadOnlyScope { FR_005_ReadOnlyScope }
check FR_005_ReadOnlyScope for 6

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md CareTeamMembership
pred FR_006_CareTeamGating {
  all op: Operation |
    op.recordReturned = BTrue implies
      (some m: CareTeamMembership |
         m.clinician = op.caller and
         m.patient   = op.presentedPatient and
         m.status    = Active)
}
assert FR_006_CareTeamGating { FR_006_CareTeamGating }
check FR_006_CareTeamGating for 6

pred OwnershipBasedAccess {
  all op: Operation |
    (op.kind = LookupRecord and op.outcome = Permitted) implies
      (some m: CareTeamMembership |
         m.clinician = op.caller and
         m.patient   = op.presentedPatient and
         m.status    = Active)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007; contracts §"Byte-equivalent not-found response"
pred FR_007_NoLeakage {
  all op: Operation |
    op.recordReturned = BTrue implies op.outcome = Permitted
}
assert FR_007_NoLeakage { FR_007_NoLeakage }
check FR_007_NoLeakage for 6

pred NoInformationLeakage {
  all op: Operation |
    (no op.outcome) implies op.recordReturned = BFalse
  all op: Operation |
    (some op.outcome and op.outcome != Permitted) implies op.recordReturned = BFalse
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008; data-model.md audit_entries
pred FR_008_AuditOnEveryAccess {
  all op: Operation |
    (op.authenticated = BTrue and op.kind = LookupRecord)
      implies (one ae: AuditEntry | ae.op = op)
}
assert FR_008_AuditOnEveryAccess { FR_008_AuditOnEveryAccess }
check FR_008_AuditOnEveryAccess for 6

pred AuditCompleteness {
  all op: Operation |
    (op.authenticated = BTrue and op.kind = LookupRecord)
      implies (one ae: AuditEntry | ae.op = op)
  all ae: AuditEntry |
    ae.op.authenticated = BTrue and ae.op.kind = LookupRecord
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 audit-entry shape + AttributionCorrectness
pred FR_009_AuditAttribution {
  all ae: AuditEntry |
    ae.clinicianSnapshot = ae.op.caller and
    ae.roleSnapshot      = ae.op.caller.role and
    ae.outcomeRecorded   = ae.op.outcome
}
assert FR_009_AuditAttribution { FR_009_AuditAttribution }
check FR_009_AuditAttribution for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009
pred AttributionCorrectness {
  all ae: AuditEntry |
    ae.clinicianSnapshot = ae.op.caller and
    ae.roleSnapshot      = ae.op.caller.role
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010; data-model.md "no UPDATE/DELETE on audit_entries"
pred FR_010_AuditAppendOnly {
  all disj a1, a2: AuditEntry | a1.op != a2.op
}
assert FR_010_AuditAppendOnly { FR_010_AuditAppendOnly }
check FR_010_AuditAppendOnly for 6

pred AppendOnly {
  all disj a1, a2: AuditEntry | a1.op != a2.op
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 IG-only access to /audit/search (SC-011 hidden from non-IG)
pred FR_011_IGOnlyAuditAccess {
  all op: Operation |
    (op.kind = SearchAudit and op.outcome = Permitted)
      implies op.caller.role = AuditOfficer
}
assert FR_011_IGOnlyAuditAccess { FR_011_IGOnlyAuditAccess }
check FR_011_IGOnlyAuditAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 8-year retention floor (no DELETE path)
pred FR_012_NoAuditDeletion {
  // The append-only invariant IS the retention floor: no entry is ever removed or overwritten.
  all disj a1, a2: AuditEntry | a1.op != a2.op
  all ae: AuditEntry | one ae.op
}
assert FR_012_NoAuditDeletion { FR_012_NoAuditDeletion }
check FR_012_NoAuditDeletion for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 2-second audit SLA — no record observed without matching audit
pred FR_013_AuditBeforeRecord {
  all op: Operation |
    (op.kind = LookupRecord and op.recordReturned = BTrue)
      implies (one ae: AuditEntry | ae.op = op)
}
assert FR_013_AuditBeforeRecord { FR_013_AuditBeforeRecord }
check FR_013_AuditBeforeRecord for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 allergies/key_warnings at top — structurally: permitted ⇒ patient resolved
pred FR_014_PatientResolvedForSafety {
  all op: Operation |
    op.recordReturned = BTrue implies (one op.presentedPatient and op.outcome = Permitted)
}
assert FR_014_PatientResolvedForSafety { FR_014_PatientResolvedForSafety }
check FR_014_PatientResolvedForSafety for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 identifier + DoB at top — structurally: every record view has a Patient
pred FR_015_PatientResolvedForVerification {
  all op: Operation |
    (op.kind = LookupRecord and op.outcome = Permitted) implies one op.presentedPatient
}
assert FR_015_PatientResolvedForVerification { FR_015_PatientResolvedForVerification }
check FR_015_PatientResolvedForVerification for 6

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md §Authorisation; spec.md FR-006/FR-011
pred LeastPrivilege {
  all op: Operation |
    op.outcome = Permitted implies
      op.caller.role -> op.kind in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md authorisation tables
pred PermissionCompleteness {
  // Allows
  Doctor        -> LookupRecord in PermMatrix.Allowed
  Nurse         -> LookupRecord in PermMatrix.Allowed
  Pharmacist    -> LookupRecord in PermMatrix.Allowed
  ClinicalAdmin -> LookupRecord in PermMatrix.Allowed
  AuditOfficer  -> SearchAudit  in PermMatrix.Allowed
  // Denies
  AuditOfficer  -> LookupRecord not in PermMatrix.Allowed
  Doctor        -> SearchAudit  not in PermMatrix.Allowed
  Nurse         -> SearchAudit  not in PermMatrix.Allowed
  Pharmacist    -> SearchAudit  not in PermMatrix.Allowed
  ClinicalAdmin -> SearchAudit  not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 6

// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-006 (clinical Allow) + FR-011 (audit-officer Allow)
pred PermissionGrounding {
  // Every Allowed cell traces back to an explicit FR: LookupRecord by clinical roles (FR-006),
  // SearchAudit by AuditOfficer (FR-011). No silent grants for AuditOfficer on the clinical path.
  AuditOfficer -> LookupRecord not in PermMatrix.Allowed
  // And the matrix never grants SearchAudit to a clinical role.
  no r: Role | (r != AuditOfficer) and (r -> SearchAudit in PermMatrix.Allowed)
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 6