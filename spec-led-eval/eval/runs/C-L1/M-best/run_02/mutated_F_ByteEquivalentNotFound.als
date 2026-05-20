// === feature_model.als — Alloy model for 009-clinician-record-access ===
// Self-contained Alloy 6 encoding of the C-L1 feature: clinician access to
// patient medical records under UK NHS regime (Q1=A), read-only (Q2=A),
// care-team-membership authorisation (Q3=A), no break-glass in v1.
//
// Anchors:
//   spec.md FR-001..FR-015, SC-001..SC-011
//   data-model.md entities Users, CareTeamMembership, AuditEntry, Patient
//   contracts/http-api.md POST /records/lookup, POST /audit/search,
//   byte-equivalent not_found response, IG-only audit endpoint.

// -----------------------------------------------------------------------------
// Closed enumerations
// -----------------------------------------------------------------------------

abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends Role {}

abstract sig OperationKind {}
one sig PostRecordsLookup, PostAuditSearch extends OperationKind {}

abstract sig Outcome {}
one sig Permitted, Denied, NotFoundOrDenied extends Outcome {}

abstract sig AuthBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthBasis {}

abstract sig ResponseShape {}
one sig RecordPayload, NotFoundShape, AuthErrorShape extends ResponseShape {}

// Flag singletons used as Boolean-ish presence markers via `lone`-fields
one sig AuthFlag {}
one sig ActiveFlag {}
one sig SafetyContent {}
one sig VerificationBlock {}

// -----------------------------------------------------------------------------
// Domain entities (data-model.md)
// -----------------------------------------------------------------------------

sig User {
  role: one Role
}

sig Patient {}

// Opaque patient identifier as presented in a request body (FR-004).
sig PidToken {}

sig CareTeamMembership {
  member: one User,
  forPatient: one Patient,
  isActive: lone ActiveFlag        // present iff status = active
}

sig AuditEntry {
  recordedClinician: one User,
  recordedRole: one Role,           // snapshot at time of access
  recordedPid: one PidToken,
  recordedKind: one OperationKind,
  recordedOutcome: one Outcome,
  recordedBasis: one AuthBasis
}

sig Operation {
  caller: one User,
  authenticated: lone AuthFlag,     // present iff request passed the auth boundary
  kind: one OperationKind,
  presentedPid: one PidToken,
  resolvedPatient: lone Patient,    // none iff the pid doesn't correspond to a Patient
  outcome: one Outcome,
  basis: one AuthBasis,
  response: one ResponseShape,
  auditEntry: lone AuditEntry,
  hasSafetyContent: lone SafetyContent,        // FR-014
  hasVerificationBlock: lone VerificationBlock // FR-015
}

// -----------------------------------------------------------------------------
// Permission matrix (contracts/http-api.md authorisation tables)
// -----------------------------------------------------------------------------

one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// -----------------------------------------------------------------------------
// Non-empty universe — ensures predicates aren't vacuously satisfied
// -----------------------------------------------------------------------------

fact F_NonEmptyUniverse {
  some User
  some Patient
  some PidToken
  some CareTeamMembership
  some AuditEntry
  some Operation
}

// -----------------------------------------------------------------------------
// Permission matrix — closed-world (contracts/http-api.md Authorisation)
// -----------------------------------------------------------------------------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Doctor         -> PostRecordsLookup) +
      (Nurse          -> PostRecordsLookup) +
      (Pharmacist     -> PostRecordsLookup) +
      (ClinicalAdmin  -> PostRecordsLookup) +
      (AuditOfficer   -> PostAuditSearch)
}

// -----------------------------------------------------------------------------
// Core domain facts
// -----------------------------------------------------------------------------

// FR-001: unauthenticated requests are rejected before any business logic;
//          no audit entry is written; no record content is returned.
fact F_AuthRequired {
  all op: Operation |
    no op.authenticated implies (
      no op.auditEntry and
      op.outcome != Permitted and
      op.response = AuthErrorShape
    )
}

// FR-006: care-team-membership gating for permitted records-lookup access.
fact F_CareTeamGating {
  all op: Operation |
    (op.kind = PostRecordsLookup and op.outcome = Permitted) implies
      (some m: CareTeamMembership |
        m.member = op.caller and
        m.forPatient = op.resolvedPatient and
        some m.isActive)
}

// FR-007 / SC-003: byte-equivalent not-found response for Denied and
//                   NotFoundOrDenied; record payload only for Permitted.
fact F_ByteEquivalentNotFound { /* MUTATED — body cleared by validator */ }

// FR-008: every authenticated records-lookup attempt produces exactly one
//          audit entry (permitted, denied, or not_found_or_denied alike).
fact F_AuditOnClinicalAccess {
  all op: Operation |
    (op.kind = PostRecordsLookup and some op.authenticated) iff (one op.auditEntry)
}

// FR-008 narrow scope: /audit/search itself is not in the patient-access
//                       audit scope — no audit entry is written.
fact F_NoAuditFromAuditSearch {
  all op: Operation | op.kind = PostAuditSearch implies no op.auditEntry
}

// FR-009 + FR-010 attribution: the audit entry's fields are pinned to the
//                                operation it records (snapshot semantics).
fact F_AuditAttribution {
  all op: Operation | some op.auditEntry implies (
    op.auditEntry.recordedClinician = op.caller and
    op.auditEntry.recordedRole       = op.caller.role and
    op.auditEntry.recordedPid        = op.presentedPid and
    op.auditEntry.recordedKind       = op.kind and
    op.auditEntry.recordedOutcome    = op.outcome and
    op.auditEntry.recordedBasis      = op.basis
  )
}

// FR-010 / FR-012 append-only: each audit entry belongs to exactly one
//                                operation. No reassignment, no sharing.
fact F_OneOpPerAuditEntry {
  all ae: AuditEntry | (one op: Operation | op.auditEntry = ae)
}

// FR-011 / SC-011: only AuditOfficer may obtain Permitted on /audit/search;
//                   all other roles receive the byte-equivalent not-found.
fact F_IGOnlyAuditEndpoint {
  all op: Operation |
    (op.kind = PostAuditSearch and op.caller.role != AuditOfficer) implies
      (op.outcome != Permitted and op.response = NotFoundShape)
}

// FR-005 + FR-011: AuditOfficer cannot use /records/lookup. Records-lookup
//                   is clinical-roles only (Doctor, Nurse, Pharmacist,
//                   ClinicalAdmin).
fact F_RecordsLookupClinicalOnly {
  all op: Operation |
    (op.kind = PostRecordsLookup and op.caller.role = AuditOfficer) implies
      (op.outcome != Permitted and op.response = NotFoundShape)
}

// FR-009: outcome and authorisation_basis are kept consistent.
fact F_OutcomeBasisConsistency {
  all op: Operation |
    (op.outcome = Permitted        iff op.basis = CareTeamMember) and
    (op.outcome = Denied           iff op.basis = NotCareTeamMember) and
    (op.outcome = NotFoundOrDenied iff op.basis = PatientNotFound)
}

// FR-013: under no circumstances may a record be observed without an audit
//          entry. (If the audit write fails, the access is refused 503.)
fact F_NoRecordWithoutAudit {
  all op: Operation |
    op.response = RecordPayload implies one op.auditEntry
}

// FR-014 / FR-015: every record-view response carries the safety-content
//                    and patient-verification blocks at the top.
fact F_SafetyAndVerificationOnRecordViews {
  all op: Operation |
    op.response = RecordPayload implies (
      some op.hasSafetyContent and
      some op.hasVerificationBlock
    )
}

// -----------------------------------------------------------------------------
// PATTERN predicates + assertions
// -----------------------------------------------------------------------------

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts auth section
pred AuthRequiredEverywhere {
  all op: Operation |
    no op.authenticated implies (
      no op.auditEntry and op.outcome != Permitted
    )
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-005,FR-011
pred LeastPrivilege {
  all op: Operation |
    op.outcome = Permitted implies
      (op.caller.role -> op.kind in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables
pred PermissionCompleteness {
  // The matrix is non-empty and every clinical role grants exactly the
  // records-lookup endpoint; the audit role grants exactly the IG endpoint.
  Doctor        -> PostRecordsLookup in PermMatrix.Allowed
  Nurse         -> PostRecordsLookup in PermMatrix.Allowed
  Pharmacist    -> PostRecordsLookup in PermMatrix.Allowed
  ClinicalAdmin -> PostRecordsLookup in PermMatrix.Allowed
  AuditOfficer  -> PostAuditSearch   in PermMatrix.Allowed
  AuditOfficer  -> PostRecordsLookup not in PermMatrix.Allowed
  Doctor        -> PostAuditSearch   not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md care_team_memberships
pred OwnershipBasedAccess {
  all op: Operation |
    (op.kind = PostRecordsLookup and op.outcome = Permitted) implies
      (some m: CareTeamMembership |
         m.member = op.caller and
         m.forPatient = op.resolvedPatient and
         some m.isActive)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003, SC-011
pred NoInformationLeakage {
  all op: Operation |
    (op.outcome = Denied or op.outcome = NotFoundOrDenied) implies
      op.response = NotFoundShape
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, SC-001, SC-002
pred AuditCompleteness {
  all op: Operation |
    (op.kind = PostRecordsLookup and some op.authenticated) implies
      (one op.auditEntry)
  all op: Operation |
    (op.kind = PostAuditSearch) implies no op.auditEntry
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, FR-012, SC-006; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  // Each audit entry is uniquely tied to one operation — no reassignment.
  all ae: AuditEntry | (one op: Operation | op.auditEntry = ae)
  // The recorded fields are pinned to the operation; no field can drift.
  all op: Operation | some op.auditEntry implies (
    op.auditEntry.recordedClinician = op.caller and
    op.auditEntry.recordedOutcome   = op.outcome and
    op.auditEntry.recordedPid       = op.presentedPid and
    op.auditEntry.recordedBasis     = op.basis
  )
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md audit_entries snapshots
pred AttributionCorrectness {
  all op: Operation | some op.auditEntry implies (
    op.auditEntry.recordedClinician = op.caller and
    op.auditEntry.recordedRole      = op.caller.role and
    op.auditEntry.recordedKind      = op.kind
  )
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// -----------------------------------------------------------------------------
// FEATURE-SPECIFIC predicates per FR-NNN
// -----------------------------------------------------------------------------

// FEATURE-SPECIFIC  ANCHOR: FR-001 — authentication required, no audit for unauth
pred FR_001_AuthRequired {
  all op: Operation |
    no op.authenticated implies (
      no op.auditEntry and
      op.outcome != Permitted and
      op.response = AuthErrorShape
    )
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 — every authenticated caller resolves to a role in the v1 catalogue
pred FR_002_RoleFromCatalogue {
  all u: User | u.role in (Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin)
  all op: Operation | one op.caller.role
}
assert FR_002_RoleFromCatalogue { FR_002_RoleFromCatalogue }
check FR_002_RoleFromCatalogue for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 — audit log supports per-patient query (data shape)
pred FR_003_AuditQueryablePerPatient {
  all ae: AuditEntry | one ae.recordedPid
}
assert FR_003_AuditQueryablePerPatient { FR_003_AuditQueryablePerPatient }
check FR_003_AuditQueryablePerPatient for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 — patient_id arrives in the request body, never in URL path
pred FR_004_PidInBodyNotPath {
  // Structural surrogate: presentedPid is a body-level field distinct from kind/URL.
  all op: Operation | one op.presentedPid and one op.kind
}
assert FR_004_PidInBodyNotPath { FR_004_PidInBodyNotPath }
check FR_004_PidInBodyNotPath for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 — read-only; only the two defined operation kinds exist
pred FR_005_ReadOnly {
  OperationKind = PostRecordsLookup + PostAuditSearch
}
assert FR_005_ReadOnly { FR_005_ReadOnly }
check FR_005_ReadOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 — care-team-membership gating (same as OwnershipBasedAccess)
pred FR_006_CareTeamGating {
  all op: Operation |
    (op.kind = PostRecordsLookup and op.outcome = Permitted) implies
      (some m: CareTeamMembership |
         m.member = op.caller and
         m.forPatient = op.resolvedPatient and
         some m.isActive)
}
assert FR_006_CareTeamGating { FR_006_CareTeamGating }
check FR_006_CareTeamGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 — byte-equivalent denied / not-found
pred FR_007_ByteEquivalentDenial {
  all op: Operation |
    (op.outcome = Denied or op.outcome = NotFoundOrDenied) implies
      op.response = NotFoundShape
}
assert FR_007_ByteEquivalentDenial { FR_007_ByteEquivalentDenial }
check FR_007_ByteEquivalentDenial for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 — always-on audit on the clinical endpoint
pred FR_008_AlwaysAudit {
  all op: Operation |
    (op.kind = PostRecordsLookup and some op.authenticated) implies
      (one op.auditEntry)
}
assert FR_008_AlwaysAudit { FR_008_AlwaysAudit }
check FR_008_AlwaysAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 — audit-entry shape carries all required fields and matches op
pred FR_009_AuditEntryShape {
  all op: Operation | some op.auditEntry implies (
    op.auditEntry.recordedClinician = op.caller and
    op.auditEntry.recordedRole      = op.caller.role and
    op.auditEntry.recordedPid       = op.presentedPid and
    op.auditEntry.recordedKind      = op.kind and
    op.auditEntry.recordedOutcome   = op.outcome and
    op.auditEntry.recordedBasis     = op.basis
  )
}
assert FR_009_AuditEntryShape { FR_009_AuditEntryShape }
check FR_009_AuditEntryShape for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 — audit immutability (no entry shared/reassigned; fields pinned)
pred FR_010_AuditImmutability {
  all ae: AuditEntry | (one op: Operation | op.auditEntry = ae)
  all op: Operation | some op.auditEntry implies (
    op.auditEntry.recordedClinician = op.caller and
    op.auditEntry.recordedOutcome   = op.outcome
  )
}
assert FR_010_AuditImmutability { FR_010_AuditImmutability }
check FR_010_AuditImmutability for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 — IG-only audit endpoint; non-IG callers get not-found
pred FR_011_IGOnly {
  all op: Operation |
    (op.kind = PostAuditSearch and op.caller.role != AuditOfficer) implies
      (op.outcome != Permitted and op.response = NotFoundShape)
}
assert FR_011_IGOnly { FR_011_IGOnly }
check FR_011_IGOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 — audit retention floor; no delete path (no orphans)
pred FR_012_NoDeletion {
  all ae: AuditEntry | (some op: Operation | op.auditEntry = ae)
}
assert FR_012_NoDeletion { FR_012_NoDeletion }
check FR_012_NoDeletion for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 — no record observed without a matching audit entry
pred FR_013_NoRecordWithoutAudit {
  all op: Operation |
    op.response = RecordPayload implies (one op.auditEntry)
}
assert FR_013_NoRecordWithoutAudit { FR_013_NoRecordWithoutAudit }
check FR_013_NoRecordWithoutAudit for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 — allergies / key warnings surfaced on every record view
pred FR_014_SafetyContentOnRecordView {
  all op: Operation |
    op.response = RecordPayload implies some op.hasSafetyContent
}
assert FR_014_SafetyContentOnRecordView { FR_014_SafetyContentOnRecordView }
check FR_014_SafetyContentOnRecordView for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 — patient identifier + DoB at top of every record view
pred FR_015_VerificationBlockOnRecordView {
  all op: Operation |
    op.response = RecordPayload implies some op.hasVerificationBlock
}
assert FR_015_VerificationBlockOnRecordView { FR_015_VerificationBlockOnRecordView }
check FR_015_VerificationBlockOnRecordView for 8

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_LeakResponse { some op: Operation | op.outcome = Denied and op.response != NotFoundShape }
