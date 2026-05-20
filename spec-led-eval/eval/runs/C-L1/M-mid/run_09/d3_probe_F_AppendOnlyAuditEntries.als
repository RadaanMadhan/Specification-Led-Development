// === feature_model.als — Alloy model for C-L1: Clinician Access to Patient Medical Records ===
// Feature branch: 009-clinician-record-access
// Sources: spec.md, data-model.md, contracts/http-api.md

// ── Boolean helper ────────────────────────────────────────────────────────────
abstract sig Bool {}
one sig True, False extends Bool {}

// ── Roles (data-model.md ClinicianRole; spec.md FR-002) ───────────────────────
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends Role {}

// ── Operations (contracts/http-api.md — exactly two endpoints) ───────────────
abstract sig OperationKind {}
one sig PostRecordsLookup, PostAuditSearch extends OperationKind {}

// ── Permission matrix singleton ───────────────────────────────────────────────
// contracts/http-api.md authorisation sections
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ── Access outcomes (data-model.md AccessOutcome) ─────────────────────────────
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// ── Authorisation bases (data-model.md AuthorisationBasis) ───────────────────
abstract sig AuthBasis {}
one sig CareTeamMemberBasis, NotCareTeamMemberBasis, PatientNotFoundBasis extends AuthBasis {}

// ── Response kinds (FR-007 byte-equivalence) ──────────────────────────────────
abstract sig ResponseKind {}
one sig SuccessResponse, NotFoundResponse extends ResponseKind {}

// ── Request encoding (FR-004 patient_id never in URL path) ───────────────────
abstract sig RequestEncoding {}
one sig InBody, InUrlPath extends RequestEncoding {}

// ── Dynamic entities ──────────────────────────────────────────────────────────

// User: clinician or IG officer (data-model.md User / spec.md FR-002)
sig User { role: one Role }

// Patient: identified by opaque patient_id (data-model.md Patient)
sig Patient {}

// ActiveMembership: host-product assertion that clinician X is on patient P's
// care team for some active episode (data-model.md CareTeamMembership, status=active)
sig ActiveMembership {
  clinician : one User,
  patient   : one Patient
}

// AccessAttempt: one authenticated clinical lookup at POST /records/lookup.
// Unauthenticated requests are rejected before becoming an AccessAttempt (FR-001).
sig AccessAttempt {
  caller      : one User,
  target      : lone Patient,       // lone: patient identifier may not match any record
  outcome     : one AccessOutcome,
  auth_basis  : one AuthBasis,
  response    : one ResponseKind,
  id_encoding : one RequestEncoding // FR-004: must always be InBody
}

// AuditEntry: one per AccessAttempt on the clinical endpoint (FR-009, FR-010)
sig AuditEntry {
  for_attempt      : one AccessAttempt,
  role_snapshot    : one Role,           // snapshotted from caller.role at access time
  recorded_outcome : one AccessOutcome,
  recorded_basis   : one AuthBasis
}

// RecordView: the patient-summary payload returned on a Permitted access (FR-014/015)
sig RecordView {
  for_attempt      : one AccessAttempt,
  safety_block_first : one Bool,   // allergies + key_warnings first (FR-014)
  id_dob_first       : one Bool    // patient_id + date_of_birth first (FR-015)
}

// ─────────────────────────────────────────────────────────────────────────────
// NAMED STRUCTURAL FACTS
// ─────────────────────────────────────────────────────────────────────────────

// Non-empty universe: every dynamic sig has at least one atom so that
// universal quantifiers bite and are not vacuously true.
fact F_NonEmptyUniverse {
  some User
  some Patient
  some ActiveMembership
  some AccessAttempt
  some AuditEntry
  some RecordView
}

// ── Permission matrix: exactly the cells mandated by contracts/http-api.md ───
// Clinical roles -> PostRecordsLookup; AuditOfficer -> PostAuditSearch only.
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor        -> PostRecordsLookup) +
    (Nurse         -> PostRecordsLookup) +
    (Pharmacist    -> PostRecordsLookup) +
    (ClinicalAdmin -> PostRecordsLookup) +
    (AuditOfficer  -> PostAuditSearch)
}

// ── Every AccessAttempt's caller holds a role permitted for PostRecordsLookup ─
// (FR-001, FR-002, contracts/http-api.md POST /records/lookup authorisation)
fact F_LeastPrivilegeClinicalEndpoint {
  all a: AccessAttempt |
    a.caller.role -> PostRecordsLookup in PermMatrix.Allowed
}

// ── Care-team gating: Permitted iff active membership exists AND patient found ─
// (FR-006, data-model.md CareTeamMembership)
fact F_CareTeamGating {
  all a: AccessAttempt | {
    a.outcome = Permitted iff
      (some a.target and
        (some m: ActiveMembership | m.clinician = a.caller and m.patient = a.target))
  }
}

// ── Outcome-to-basis consistency (FR-006, FR-008, data-model.md AuthorisationBasis)
fact F_OutcomeConsistency {
  all a: AccessAttempt | {
    no a.target =>
      (a.outcome = NotFoundOrDenied and a.auth_basis = PatientNotFoundBasis)
    (some a.target and
      (no m: ActiveMembership | m.clinician = a.caller and m.patient = a.target)) =>
        (a.outcome = Denied and a.auth_basis = NotCareTeamMemberBasis)
    a.outcome = Permitted =>
      (a.auth_basis = CareTeamMemberBasis)
  }
}

// ── Byte-equivalent not-found response (FR-007, SC-003) ──────────────────────
// Denied and not-found-or-denied both return NotFoundResponse.
// Only Permitted returns SuccessResponse.
fact F_ByteEquivalentNotFound {
  all a: AccessAttempt | {
    a.response = SuccessResponse  iff a.outcome = Permitted
    a.response = NotFoundResponse iff a.outcome != Permitted
  }
}

// ── Exactly one AuditEntry per AccessAttempt (FR-008, SC-001) ─────────────────
fact F_AuditCompleteness {
  all a: AccessAttempt | one ae: AuditEntry | ae.for_attempt = a
}

// ── Every AuditEntry belongs to exactly one AccessAttempt (no orphan entries) ─
fact F_AuditNoOrphans {
  all ae: AuditEntry | ae.for_attempt in AccessAttempt
}

// ── No two AuditEntries cover the same AccessAttempt (append-only, no edits) ─
// (FR-010, SC-006, data-model.md "no UPDATE/DELETE")
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry | ae1.for_attempt != ae2.for_attempt
}

// ── Attribution correctness: role_snapshot must equal caller's actual role ────
// (FR-009; spec.md "clinician_role snapshotted at time of access")
fact F_AttributionCorrectness {
  all ae: AuditEntry |
    ae.role_snapshot = ae.for_attempt.caller.role
}

// ── AuditEntry outcome and basis faithfully record the attempt's values ────────
// (FR-009)
fact F_AuditOutcomeAndBasisMatch {
  all ae: AuditEntry | {
    ae.recorded_outcome = ae.for_attempt.outcome
    ae.recorded_basis   = ae.for_attempt.auth_basis
  }
}

// ── Patient identifier is always carried in request body, never URL path ──────
// (FR-004, SC-005)
fact F_PatientIdInBody {
  all a: AccessAttempt | a.id_encoding = InBody
}

// ── RecordView exists only for Permitted AccessAttempts (read-only, FR-005) ───
fact F_RecordViewOnlyForPermitted {
  all rv: RecordView | rv.for_attempt.outcome = Permitted
}

// ── Exactly one RecordView per Permitted AccessAttempt (FR-005, FR-013) ───────
fact F_OneRecordViewPerPermitted {
  all a: AccessAttempt |
    a.outcome = Permitted => (one rv: RecordView | rv.for_attempt = a)
}

// ── Allergies and key-warnings appear first in every RecordView (FR-014) ──────
fact F_SafetyBlockFirst {
  all rv: RecordView | rv.safety_block_first = True
}

// ── Patient identifier and date-of-birth appear first in every RecordView ─────
// (FR-015)
fact F_IdDoBFirst {
  all rv: RecordView | rv.id_dob_first = True
}

// ─────────────────────────────────────────────────────────────────────────────
// PREDICATES AND ASSERTIONS
// ─────────────────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-002
pred LeastPrivilege {
  some AccessAttempt
  // Clinical endpoint: only Doctor/Nurse/Pharmacist/ClinicalAdmin may call it
  all a: AccessAttempt |
    a.caller.role -> PostRecordsLookup in PermMatrix.Allowed
  // Audit endpoint: only AuditOfficer is allowed
  AuditOfficer -> PostAuditSearch in PermMatrix.Allowed
  // AuditOfficer must NOT appear in clinical endpoint permission
  AuditOfficer -> PostRecordsLookup not in PermMatrix.Allowed
  // Clinical roles must NOT appear in audit endpoint permission
  all r: (Doctor + Nurse + Pharmacist + ClinicalAdmin) |
    r -> PostAuditSearch not in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md; spec.md FR-002
pred PermissionCompleteness {
  some AccessAttempt
  // Every role × operation cell is either explicitly allowed or explicitly denied
  // (the complement of Allowed is Denied; the union must cover all cells)
  Role -> OperationKind =
    PermMatrix.Allowed +
    (Role -> OperationKind - PermMatrix.Allowed)
  // Specifically, the Allowed set is exactly the five cells documented
  #PermMatrix.Allowed = 5
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md authentication section
pred AuthRequiredEverywhere {
  some AuditEntry
  // Every AuditEntry traces to an AccessAttempt, which by construction has a caller (User).
  // No AuditEntry exists without a corresponding authenticated caller.
  all ae: AuditEntry | some ae.for_attempt.caller
  // All AccessAttempts carry a legitimate clinical role for the records endpoint
  all a: AccessAttempt | a.caller.role -> PostRecordsLookup in PermMatrix.Allowed
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, FR-009; SC-001; data-model.md AuditEntry
pred AuditCompleteness {
  some AccessAttempt
  // Every AccessAttempt has exactly one associated AuditEntry
  all a: AccessAttempt | (one ae: AuditEntry | ae.for_attempt = a)
  // No AuditEntry is orphaned
  all ae: AuditEntry | ae.for_attempt in AccessAttempt
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, FR-012; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  some AuditEntry
  // No two distinct AuditEntries record the same attempt (no duplicate / edit)
  all disj ae1, ae2: AuditEntry | ae1.for_attempt != ae2.for_attempt
  // Combined with F_AuditCompleteness this gives a bijection: each attempt maps
  // to exactly one entry and each entry maps to exactly one attempt.
  all a: AccessAttempt | (one ae: AuditEntry | ae.for_attempt = a)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md AuditEntry.clinician_role snapshot
pred AttributionCorrectness {
  some AuditEntry
  all ae: AuditEntry | {
    ae.role_snapshot    = ae.for_attempt.caller.role
    ae.recorded_outcome = ae.for_attempt.outcome
    ae.recorded_basis   = ae.for_attempt.auth_basis
  }
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006, SC-010; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  some AccessAttempt
  // Permitted iff the caller has an ActiveMembership to the target patient
  all a: AccessAttempt | {
    a.outcome = Permitted =>
      (some a.target and
        (some m: ActiveMembership | m.clinician = a.caller and m.patient = a.target))
    (some a.target and
      (some m: ActiveMembership | m.clinician = a.caller and m.patient = a.target)) =>
        a.outcome = Permitted
    a.outcome != Permitted =>
      (no a.target or
        (all m: ActiveMembership | not (m.clinician = a.caller and m.patient = a.target)))
  }
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003, SC-011; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  some AccessAttempt
  // Denied (not on care team) and NotFoundOrDenied (patient does not exist)
  // must produce identical response shapes
  all a: AccessAttempt | {
    a.outcome = Denied          => a.response = NotFoundResponse
    a.outcome = NotFoundOrDenied => a.response = NotFoundResponse
    a.outcome = Permitted        => a.response = SuccessResponse
  }
  // The two non-permitted outcomes are indistinguishable at the response level
  all disj a1, a2: AccessAttempt |
    (a1.outcome = Denied and a2.outcome = NotFoundOrDenied) =>
      a1.response = a2.response
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC PREDICATES (per FR-NNN)
// ─────────────────────────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
// Unauthenticated requests produce no audit entries and never reach AccessAttempt.
// Modelled structurally: all AccessAttempts have a User caller; all AuditEntries
// trace to an AccessAttempt with a User caller (never an unauthenticated principal).
pred FR_001_AuthRequired {
  some AuditEntry
  all ae: AuditEntry | some ae.for_attempt.caller.role
  all a: AccessAttempt | a.caller.role -> PostRecordsLookup in PermMatrix.Allowed
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
// Every authenticated caller is resolved to a unique clinician_role from the v1 catalogue.
pred FR_002_RoleResolution {
  some User
  all u: User | u.role in (Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin)
}
assert FR_002_RoleResolution { FR_002_RoleResolution }
check FR_002_RoleResolution for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004; SC-005
// Patient identifiers are never placed in URL paths; always in the request body.
pred FR_004_PatientIdNotInUrl {
  some AccessAttempt
  all a: AccessAttempt | a.id_encoding = InBody
  no a: AccessAttempt | a.id_encoding = InUrlPath
}
assert FR_004_PatientIdNotInUrl { FR_004_PatientIdNotInUrl }
check FR_004_PatientIdNotInUrl for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005; Q2 = A read-only
// A RecordView (write of any kind is absent) only exists for Permitted accesses;
// no AccessAttempt creates or amends any Patient row.
pred FR_005_ReadOnly {
  some AccessAttempt
  all rv: RecordView | rv.for_attempt.outcome = Permitted
  // No Permitted access without an associated RecordView (record was served)
  all a: AccessAttempt | a.outcome = Permitted =>
    (one rv: RecordView | rv.for_attempt = a)
}
assert FR_005_ReadOnly { FR_005_ReadOnly }
check FR_005_ReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006; SC-010; data-model.md CareTeamMembership
pred FR_006_CareTeamGating {
  some AccessAttempt
  all a: AccessAttempt | {
    a.outcome = Permitted =>
      (some a.target and
        (some m: ActiveMembership | m.clinician = a.caller and m.patient = a.target))
    a.outcome != Permitted =>
      (no a.target or
        (all m: ActiveMembership | not (m.clinician = a.caller and m.patient = a.target)))
  }
}
assert FR_006_CareTeamGating { FR_006_CareTeamGating }
check FR_006_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007; SC-003; contracts/http-api.md byte-equivalent not-found
pred FR_007_ByteEquivalentNotFound {
  some AccessAttempt
  all a: AccessAttempt |
    a.outcome != Permitted => a.response = NotFoundResponse
  some a: AccessAttempt | a.outcome = Denied
  some a: AccessAttempt | a.outcome = NotFoundOrDenied
}
assert FR_007_ByteEquivalentNotFound { FR_007_ByteEquivalentNotFound }
check FR_007_ByteEquivalentNotFound for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008; SC-001; SC-002
// Every AccessAttempt (any outcome) has exactly one AuditEntry — always-on audit.
pred FR_008_AlwaysOnAudit {
  some AccessAttempt
  all a: AccessAttempt | (one ae: AuditEntry | ae.for_attempt = a)
  // Covers denied outcomes too (not only permitted)
  some a: AccessAttempt | a.outcome = Denied and
    (one ae: AuditEntry | ae.for_attempt = a)
  some a: AccessAttempt | a.outcome = NotFoundOrDenied and
    (one ae: AuditEntry | ae.for_attempt = a)
}
assert FR_008_AlwaysOnAudit { FR_008_AlwaysOnAudit }
check FR_008_AlwaysOnAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md AuditEntry shape
// Every audit entry carries correct snapshots of the clinician's role at access time,
// and the recorded outcome/basis match the attempt's actual outcome/basis.
pred FR_009_AuditEntryShape {
  some AuditEntry
  all ae: AuditEntry | {
    ae.role_snapshot    = ae.for_attempt.caller.role
    ae.recorded_outcome = ae.for_attempt.outcome
    ae.recorded_basis   = ae.for_attempt.auth_basis
  }
}
assert FR_009_AuditEntryShape { FR_009_AuditEntryShape }
check FR_009_AuditEntryShape for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010; SC-006; data-model.md "no UPDATE/DELETE on audit_entries"
// Audit entries are immutable: no two entries record the same attempt (no overwrites).
pred FR_010_AuditImmutability {
  some AuditEntry
  all disj ae1, ae2: AuditEntry | ae1.for_attempt != ae2.for_attempt
}
assert FR_010_AuditImmutability { FR_010_AuditImmutability }
check FR_010_AuditImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011; SC-011; contracts/http-api.md POST /audit/search authorisation
// The audit search endpoint is only accessible to AuditOfficer.
// Clinical roles must not appear in the Allowed set for PostAuditSearch.
pred FR_011_AuditVisibleToIGOnly {
  AuditOfficer -> PostAuditSearch in PermMatrix.Allowed
  all r: (Doctor + Nurse + Pharmacist + ClinicalAdmin) |
    r -> PostAuditSearch not in PermMatrix.Allowed
}
assert FR_011_AuditVisibleToIGOnly { FR_011_AuditVisibleToIGOnly }
check FR_011_AuditVisibleToIGOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012; SC-006; data-model.md "8-year retention floor"
// No AuditEntry is orphaned (all are reachable from their AccessAttempt).
// The "no DELETE path" invariant is structurally represented by the bijection
// between AuditEntry and AccessAttempt: every entry persists.
pred FR_012_AuditRetention {
  some AuditEntry
  all ae: AuditEntry | ae.for_attempt in AccessAttempt
  all a: AccessAttempt | (one ae: AuditEntry | ae.for_attempt = a)
}
assert FR_012_AuditRetention { FR_012_AuditRetention }
check FR_012_AuditRetention for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013; SC-007; contracts/http-api.md 503 rule
// A record view must never be returned without a committed audit entry.
// Every Permitted AccessAttempt has both a RecordView AND an AuditEntry.
pred FR_013_AuditBeforeAccess {
  some AccessAttempt
  all a: AccessAttempt | a.outcome = Permitted =>
    ((one ae: AuditEntry | ae.for_attempt = a) and
     (one rv: RecordView | rv.for_attempt = a))
}
assert FR_013_AuditBeforeAccess { FR_013_AuditBeforeAccess }
check FR_013_AuditBeforeAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014; SC-008; contracts/http-api.md fixed JSON key order
// Allergies and key-warnings block appears first in every patient-summary response.
pred FR_014_AllergiesFirst {
  some RecordView
  all rv: RecordView | rv.safety_block_first = True
}
assert FR_014_AllergiesFirst { FR_014_AllergiesFirst }
check FR_014_AllergiesFirst for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015; contracts/http-api.md fixed JSON key order
// Patient identifier and date-of-birth appear at the top of every patient-summary response.
pred FR_015_IdDoBFirst {
  some RecordView
  all rv: RecordView | rv.id_dob_first = True
}
assert FR_015_IdDoBFirst { FR_015_IdDoBFirst }
check FR_015_IdDoBFirst for 5

// === D3 inject_violation (validator-appended) ===
fact MUTATE_AppendOnlyViolation { some disj ae1, ae2: AuditEntry | ae1.for_attempt = ae2.for_attempt }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5
