// === feature_model.als — Alloy model for Clinician Access to Patient Medical Records (v1) ===
// Feature: C-L1  (folder: 009-clinician-record-access)
// Artefacts: spec.md, data-model.md, contracts/http-api.md
// All sigs, facts, predicates and assertions are self-contained.

// ═══════════════════════════════════════════════════════════════════════════
// ENUMERATIONS — abstract sig + one-sig atoms
// ═══════════════════════════════════════════════════════════════════════════

abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends Role {}

abstract sig OperationKind {}
one sig LookupRecord, SearchAudit extends OperationKind {}

abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

abstract sig AuthBasis {}
one sig CareTeamMemberBasis, NotCareTeamMemberBasis, PatientNotFoundBasis extends AuthBasis {}

// External response shape as seen by an API caller (for no-leakage modeling)
abstract sig ResponseShape {}
one sig SuccessShape, NotFoundShape extends ResponseShape {}

// ═══════════════════════════════════════════════════════════════════════════
// PERMISSION MATRIX
// Canonical singleton-field pattern; cells listed explicitly for closed-world.
// ═══════════════════════════════════════════════════════════════════════════

one sig PermMatrix {
  Allowed: set Role -> OperationKind
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-006, FR-011
fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor       -> LookupRecord) +
    (Nurse        -> LookupRecord) +
    (Pharmacist   -> LookupRecord) +
    (ClinicalAdmin -> LookupRecord) +
    (AuditOfficer -> SearchAudit)
}

// ═══════════════════════════════════════════════════════════════════════════
// DYNAMIC ENTITIES
// ═══════════════════════════════════════════════════════════════════════════

sig User {
  role: one Role
}

sig Patient {}

// CareTeamMembership: host-product assertion that clinician is on patient's care team.
// data-model.md PK = (clinician_id, patient_id, episode_of_care_id); status = active|ended.
sig CareTeamMembership {
  ctmClinician : one User,
  ctmPatient   : one Patient,
  ctmStatus    : one MembershipStatus
}

// AccessAttempt: one authenticated request that reached the service layer.
// Unauthenticated requests are rejected before this point (FR-001) and are
// not modelled as AccessAttempts; they produce no AuditEntry.
sig AccessAttempt {
  caller          : one User,
  kind            : one OperationKind,
  // lone: patient may not exist in the system (outcome = NotFoundOrDenied)
  targetPatient   : lone Patient,
  outcome         : one AccessOutcome,
  basis           : one AuthBasis,
  externalResponse: one ResponseShape
}

// AuditEntry: immutable append-only record of one access attempt (FR-009, FR-010).
sig AuditEntry {
  forAttempt   : one AccessAttempt,
  recordedRole : one Role
}

// ═══════════════════════════════════════════════════════════════════════════
// STRUCTURAL FACTS
// ═══════════════════════════════════════════════════════════════════════════

// Non-empty universe for all dynamic sigs so quantified assertions are non-vacuous.
fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some AccessAttempt
  some AuditEntry
}

// Only callers whose role is permitted for the operation kind may make attempts.
// FEATURE-SPECIFIC  ANCHOR: FR-001, FR-002; contracts/http-api.md authentication
fact F_AuthorisedOperationsOnly {
  all a: AccessAttempt |
    a.caller.role -> a.kind in PermMatrix.Allowed
}

// Care-team gating (biconditional): Permitted iff active membership, Denied iff patient
// exists but no membership, NotFoundOrDenied iff patient absent from the system.
// FEATURE-SPECIFIC  ANCHOR: FR-006, SC-010; data-model.md CareTeamMembership
fact F_CareTeamGating {
  all a: AccessAttempt | a.kind = LookupRecord implies {
    (a.outcome = Permitted) iff
      (some m: CareTeamMembership |
        m.ctmClinician = a.caller and
        m.ctmPatient = a.targetPatient and
        m.ctmStatus = Active)
  }
}

// Authorisation basis is consistent with outcome.
// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md AuthorisationBasis enum
fact F_BasisOutcomeConsistency {
  all a: AccessAttempt | a.kind = LookupRecord implies {
    (a.outcome = Permitted         implies a.basis = CareTeamMemberBasis)    and
    (a.outcome = Denied            implies a.basis = NotCareTeamMemberBasis) and
    (a.outcome = NotFoundOrDenied  implies a.basis = PatientNotFoundBasis)
  }
}

// Target patient presence is consistent with outcome.
// FEATURE-SPECIFIC  ANCHOR: FR-007, FR-009; contracts/http-api.md behaviour section
fact F_PatientExistenceConsistency {
  all a: AccessAttempt | {
    a.outcome = Permitted        implies (one  a.targetPatient) and
    a.outcome = Denied           implies (one  a.targetPatient) and
    a.outcome = NotFoundOrDenied implies (no   a.targetPatient)
  }
}

// No-information-leakage: Denied and NotFoundOrDenied share an identical external shape.
// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003; contracts/http-api.md byte-equivalent not-found
fact F_NoInformationLeakageResponse {
  all a: AccessAttempt | {
    (a.outcome = Permitted        implies a.externalResponse = SuccessShape)  and
    (a.outcome = Denied           implies a.externalResponse = NotFoundShape) and
    (a.outcome = NotFoundOrDenied implies a.externalResponse = NotFoundShape)
  }
}

// AuditCompleteness: every LookupRecord attempt has exactly one AuditEntry.
// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, FR-009, SC-001, SC-002; data-model.md AuditEntry
fact F_AuditCompletenessForLookup {
  all a: AccessAttempt | a.kind = LookupRecord implies
    (one e: AuditEntry | e.forAttempt = a)
}

// AppendOnly: forAttempt is injective — no two entries record the same attempt.
// This captures "no UPDATE; no replacement entry overwrites an existing one."
// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, SC-006; data-model.md "no UPDATE/DELETE"
fact F_AppendOnlyAuditEntries { /* MUTATED — body cleared by validator */ }

// AuditEntry only exists for LookupRecord attempts (SearchAudit does not write patient-level audit).
// FEATURE-SPECIFIC  ANCHOR: FR-008; contracts/http-api.md /audit/search behaviour
fact F_AuditEntriesOnlyForLookup {
  all e: AuditEntry | e.forAttempt.kind = LookupRecord
}

// Attribution correctness: the role recorded in the audit entry equals the caller's actual role.
// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md AuditEntry clinician_role (snapshotted)
fact F_AttributionCorrectness {
  all e: AuditEntry | e.recordedRole = e.forAttempt.caller.role
}

// ═══════════════════════════════════════════════════════════════════════════
// PREDICATES  (one per pattern or FR; each asserted + checked below)
// ═══════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission table; spec.md FR-006, FR-011
pred LeastPrivilege {
  some AccessAttempt
  // No caller performs an operation outside their role's permission matrix entry.
  all a: AccessAttempt | a.caller.role -> a.kind in PermMatrix.Allowed
  // AuditOfficer is never permitted to call LookupRecord.
  no a: AccessAttempt | a.kind = LookupRecord and a.caller.role = AuditOfficer
  // No clinical role is permitted to call SearchAudit.
  all a: AccessAttempt | a.kind = SearchAudit implies a.caller.role = AuditOfficer
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
pred PermissionCompleteness {
  // Exactly 5 allowed cells in the v1 matrix (4 clinical × LookupRecord + 1 IG × SearchAudit).
  #(PermMatrix.Allowed) = 5
  // Every role has at least one allowed operation — no role is entirely locked out.
  all r: Role | some r.(PermMatrix.Allowed)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, SC-004; contracts/http-api.md authentication section
pred AuthRequiredEverywhere {
  some AccessAttempt
  // Every attempt is tied to a User with a known, valid v1 role — no anonymous callers.
  all a: AccessAttempt | a.caller.role in (Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin)
  // No AccessAttempt has a caller without a role (one is enforced by sig declaration,
  // but we make it explicit for the assertion).
  all a: AccessAttempt | one a.caller
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, FR-009, SC-001, SC-002; data-model.md AuditEntry
pred AuditCompleteness {
  some a: AccessAttempt | a.kind = LookupRecord
  // Every LookupRecord attempt — permitted, denied, or not-found-or-denied — has exactly one audit entry.
  all a: AccessAttempt | a.kind = LookupRecord implies
    (one e: AuditEntry | e.forAttempt = a)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, SC-006; data-model.md "Append-only: no UPDATE/DELETE"
pred AppendOnly {
  some AuditEntry
  // forAttempt is injective: no two distinct entries record the same attempt.
  all disj e1, e2: AuditEntry | e1.forAttempt != e2.forAttempt
  // Every entry is linked to a LookupRecord attempt (no fabricated entries).
  all e: AuditEntry | e.forAttempt.kind = LookupRecord
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md AuditEntry clinician_role snapshot
pred AttributionCorrectness {
  some AuditEntry
  all e: AuditEntry | e.recordedRole = e.forAttempt.caller.role
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006, SC-010; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  some a: AccessAttempt | a.kind = LookupRecord
  all a: AccessAttempt | a.kind = LookupRecord implies {
    (a.outcome = Permitted) iff
      (some m: CareTeamMembership |
        m.ctmClinician = a.caller and
        m.ctmPatient   = a.targetPatient and
        m.ctmStatus    = Active)
  }
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003, SC-011; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  // Need both outcomes present to make the assertion non-vacuous.
  some a1: AccessAttempt | a1.kind = LookupRecord and a1.outcome = Denied
  some a2: AccessAttempt | a2.kind = LookupRecord and a2.outcome = NotFoundOrDenied
  // Both refusal outcomes map to the identical external response shape.
  all a: AccessAttempt | {
    (a.outcome = Denied           implies a.externalResponse = NotFoundShape) and
    (a.outcome = NotFoundOrDenied implies a.externalResponse = NotFoundShape) and
    (a.outcome = Permitted        implies a.externalResponse = SuccessShape)
  }
  // Denied and NotFoundOrDenied are indistinguishable to an external observer.
  no disj a1, a2: AccessAttempt |
    a1.outcome = Denied and a2.outcome = NotFoundOrDenied and
    a1.externalResponse != a2.externalResponse
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: PrivilegeMonotonicity  ANCHOR: contracts/http-api.md permission table; spec.md role descriptions
// v1 roles are disjoint (not hierarchically nested): clinical roles own LookupRecord,
// IG role owns SearchAudit. Neither is a superset of the other.
pred PrivilegeMonotonicity {
  // AuditOfficer has no LookupRecord permission.
  AuditOfficer -> LookupRecord not in PermMatrix.Allowed
  // No clinical role has SearchAudit permission.
  all r: Role | r != AuditOfficer implies r -> SearchAudit not in PermMatrix.Allowed
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-008; contracts/http-api.md 400 validation_error
// Requests that fail validation (missing patient_id → 400) never become AccessAttempts
// and never produce AuditEntries.  Within the service layer, a Permitted outcome implies
// the patient was successfully resolved.
pred ValidationBeforeMutation {
  some AuditEntry
  all e: AuditEntry | e.forAttempt.kind = LookupRecord
  // Permitted access always has a resolved target patient.
  all e: AuditEntry | e.forAttempt.outcome = Permitted implies (one e.forAttempt.targetPatient)
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ───────────────────────────────────────────────────────────
// FEATURE-SPECIFIC FR PREDICATES
// ───────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001, SC-004
pred FR_001_AuthRequired {
  some AccessAttempt
  all a: AccessAttempt | one a.caller
  all a: AccessAttempt | a.caller.role in (Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002; data-model.md ClinicianRole enum
pred FR_002_RoleResolution {
  some User
  all u: User | one u.role
  all u: User | u.role in (Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin)
}
assert FR_002_RoleResolution { FR_002_RoleResolution }
check FR_002_RoleResolution for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005; spec.md Q2=A read-only, no write endpoint exists
pred FR_005_ReadOnly {
  some AccessAttempt
  // In v1 the only operation kinds are LookupRecord and SearchAudit — both reads.
  all a: AccessAttempt | a.kind = LookupRecord or a.kind = SearchAudit
  // Structural: no write OperationKind has been introduced.
  LookupRecord != SearchAudit
}
assert FR_005_ReadOnly { FR_005_ReadOnly }
check FR_005_ReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006, SC-010; data-model.md CareTeamMembership
pred FR_006_CareTeamGating {
  some a: AccessAttempt | a.kind = LookupRecord
  // Permitted access requires an active care-team membership — no exceptions, no break-glass.
  all a: AccessAttempt | a.outcome = Permitted implies
    (some m: CareTeamMembership |
      m.ctmClinician = a.caller and m.ctmPatient = a.targetPatient and m.ctmStatus = Active)
  // Active membership and patient existence together are necessary and sufficient for Permitted.
  all a: AccessAttempt | a.kind = LookupRecord implies {
    (a.outcome = Permitted) iff
      (some m: CareTeamMembership |
        m.ctmClinician = a.caller and m.ctmPatient = a.targetPatient and m.ctmStatus = Active)
  }
}
assert FR_006_CareTeamGating { FR_006_CareTeamGating }
check FR_006_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007, SC-003; contracts/http-api.md byte-equivalent not-found response
pred FR_007_ByteEquivalentDenied {
  some a1: AccessAttempt | a1.outcome = Denied
  some a2: AccessAttempt | a2.outcome = NotFoundOrDenied
  all a: AccessAttempt |
    (a.outcome = Denied or a.outcome = NotFoundOrDenied) implies
      a.externalResponse = NotFoundShape
}
assert FR_007_ByteEquivalentDenied { FR_007_ByteEquivalentDenied }
check FR_007_ByteEquivalentDenied for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008, SC-001, SC-002; data-model.md AuditEntry always-on
pred FR_008_AlwaysOnAudit {
  some a: AccessAttempt | a.kind = LookupRecord
  // Every LookupRecord attempt, regardless of outcome, produces exactly one AuditEntry.
  all a: AccessAttempt | a.kind = LookupRecord implies
    (one e: AuditEntry | e.forAttempt = a)
}
assert FR_008_AlwaysOnAudit { FR_008_AlwaysOnAudit }
check FR_008_AlwaysOnAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md AuditEntry fields
pred FR_009_AuditFields {
  some AuditEntry
  all e: AuditEntry | {
    one e.forAttempt
    one e.recordedRole
    // Recorded role is the snapshot of the caller's role at access time.
    e.recordedRole = e.forAttempt.caller.role
    one e.forAttempt.outcome
    one e.forAttempt.basis
  }
}
assert FR_009_AuditFields { FR_009_AuditFields }
check FR_009_AuditFields for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010, SC-006; data-model.md "Append-only: no UPDATE/DELETE"
pred FR_010_AuditImmutable {
  some AuditEntry
  // forAttempt is injective: no attempt is recorded more than once (no "update" semantics).
  all disj e1, e2: AuditEntry | e1.forAttempt != e2.forAttempt
}
assert FR_010_AuditImmutable { FR_010_AuditImmutable }
check FR_010_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011, SC-011; contracts/http-api.md /audit/search authorisation
pred FR_011_IGRoleOnlyAuditSearch {
  some a: AccessAttempt | a.kind = SearchAudit
  // Only AuditOfficer role can invoke the audit-search endpoint.
  all a: AccessAttempt | a.kind = SearchAudit implies a.caller.role = AuditOfficer
  // No clinical role may call SearchAudit.
  no a: AccessAttempt |
    a.kind = SearchAudit and
    a.caller.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}
assert FR_011_IGRoleOnlyAuditSearch { FR_011_IGRoleOnlyAuditSearch }
check FR_011_IGRoleOnlyAuditSearch for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013, SC-007; contracts/http-api.md 503 service_unavailable
// Models the invariant: no clinician observes record content without a committed audit entry.
// (The 503 path refuses access AND skips the audit; the model expresses the converse —
// a Permitted outcome always has a matching AuditEntry.)
pred FR_013_AuditSLAEnforced {
  some a: AccessAttempt | a.kind = LookupRecord and a.outcome = Permitted
  all a: AccessAttempt | (a.kind = LookupRecord and a.outcome = Permitted) implies
    (some e: AuditEntry | e.forAttempt = a)
}
assert FR_013_AuditSLAEnforced { FR_013_AuditSLAEnforced }
check FR_013_AuditSLAEnforced for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014, FR-015, SC-008; spec.md clinical-safety guards
// Structural claim: every Permitted LookupRecord response carries the SuccessShape
// (the shape that includes the patient summary with allergies/warnings/id/DoB at the top).
// JSON key ordering is a runtime property; Alloy encodes the structural pre-condition.
pred FR_014_FR_015_SafetyDataInSuccessResponse {
  some a: AccessAttempt | a.kind = LookupRecord and a.outcome = Permitted
  all a: AccessAttempt | (a.kind = LookupRecord and a.outcome = Permitted) implies
    a.externalResponse = SuccessShape
}
assert FR_014_FR_015_SafetyDataInSuccessResponse { FR_014_FR_015_SafetyDataInSuccessResponse }
check FR_014_FR_015_SafetyDataInSuccessResponse for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_AppendOnlyViolation { some disj e1, e2: AuditEntry | e1.forAttempt = e2.forAttempt }
