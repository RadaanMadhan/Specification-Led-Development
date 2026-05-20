// === feature_model.als — Alloy 6 model for Clinician Access to Patient Medical Records (C-L1) ===
// Branch: 009-clinician-record-access | Spec v1 | Date: 2026-05-17
//
// Covers:
//   spec.md FR-001 through FR-015
//   data-model.md entities: User, Patient, CareTeamMembership, AuditEntry
//   contracts/http-api.md: POST /records/lookup, POST /audit/search, permission matrix
//
// Patterns applied:
//   LeastPrivilege, PermissionCompleteness, AuthRequiredEverywhere,
//   AuditCompleteness, AppendOnly, AttributionCorrectness,
//   OwnershipBasedAccess, NoInformationLeakage, ValidationBeforeMutation

// ─────────────────────────────────────────────────────────────────────────────
// ROLE CATALOGUE  (data-model.md ClinicianRole enum; FR-002)
// ─────────────────────────────────────────────────────────────────────────────

abstract sig ClinicianRole {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends ClinicianRole {}

// Helper: the four roles that may call POST /records/lookup
pred isClinicalRole[r: ClinicianRole] {
  r in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}

// ─────────────────────────────────────────────────────────────────────────────
// ENUMERATIONS
// ─────────────────────────────────────────────────────────────────────────────

abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

abstract sig AuthBasis {}
one sig CareTeamMemberBasis, NotCareTeamMemberBasis, PatientNotFoundBasis extends AuthBasis {}

// Two endpoints in v1 (contracts/http-api.md)
abstract sig OperationKind {}
one sig RecordsLookup, AuditSearch extends OperationKind {}

// Externally observable response shapes (FR-007 byte-equivalence)
abstract sig ResponseShape {}
one sig OkShape, NotFoundShape extends ResponseShape {}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (contracts/http-api.md — Authorisation sections)
// ─────────────────────────────────────────────────────────────────────────────

one sig PermMatrix { Allowed: set ClinicianRole -> OperationKind }

// ─────────────────────────────────────────────────────────────────────────────
// DYNAMIC ENTITIES
// ─────────────────────────────────────────────────────────────────────────────

// data-model.md: users table (clinician or IG officer)
sig User { role: one ClinicianRole }

// data-model.md: patients table
sig Patient {}

// data-model.md: care_team_memberships table
// Composite PK (clinician_id, patient_id, episode_of_care_id) is approximated
// here as one membership per (member, carePatient) pair for structural analysis.
sig CareTeamMembership {
  member:      one User,
  carePatient: one Patient,
  mstatus:     one MembershipStatus
}

// data-model.md: audit_entries table — append-only, FR-009 fields
sig AuditEntry {
  aClinician:    one User,
  aSnapshotRole: one ClinicianRole,   // snapshot of caller's role at access time
  aPatient:      lone Patient,        // lone: entry is written even if patient absent
  aOutcome:      one AccessOutcome,
  aBasis:        one AuthBasis
}

// An AccessAttempt models one request that has PASSED authentication
// (unauthenticated requests are rejected before the service layer and never modelled here).
// FR-001: every AccessAttempt has a resolved, authenticated caller.
sig AccessAttempt {
  aCaller:    one User,
  aKind:      one OperationKind,
  aTarget:    lone Patient,       // lone: the patient_id may not correspond to a real patient
  aOutcome:   one AccessOutcome,
  aResponse:  one ResponseShape,
  aAudit:     lone AuditEntry    // lone: AuditSearch attempts produce no patient-level audit entry
}

// ─────────────────────────────────────────────────────────────────────────────
// NON-EMPTY UNIVERSE
// ─────────────────────────────────────────────────────────────────────────────

fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some AuditEntry
  some AccessAttempt
}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (contracts/http-api.md authorisation tables)
// Doctor / Nurse / Pharmacist / ClinicalAdmin → POST /records/lookup : ALLOWED
// AuditOfficer                               → POST /records/lookup : DENIED
// AuditOfficer                               → POST /audit/search   : ALLOWED
// Clinical roles                             → POST /audit/search   : DENIED
// ─────────────────────────────────────────────────────────────────────────────

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor       -> RecordsLookup) +
    (Nurse        -> RecordsLookup) +
    (Pharmacist   -> RecordsLookup) +
    (ClinicalAdmin -> RecordsLookup) +
    (AuditOfficer -> AuditSearch)
}

// ─────────────────────────────────────────────────────────────────────────────
// CALLER MUST OPERATE IN AN ALLOWED CELL  (LeastPrivilege enforcement)
// ─────────────────────────────────────────────────────────────────────────────

fact F_CallerOperationConstraint {
  all a: AccessAttempt | (a.aCaller.role -> a.aKind) in PermMatrix.Allowed
}

// ─────────────────────────────────────────────────────────────────────────────
// CARE-TEAM GATING  (FR-006, SC-010)
// Permitted outcome on RecordsLookup requires an active CareTeamMembership.
// ─────────────────────────────────────────────────────────────────────────────

fact F_CareTeamGating { /* MUTATED — body cleared by validator */ }

// ─────────────────────────────────────────────────────────────────────────────
// PERMITTED REQUIRES A REAL PATIENT  (structural consistency)
// ─────────────────────────────────────────────────────────────────────────────

fact F_PermittedRequiresPatient {
  all a: AccessAttempt |
    a.aOutcome = Permitted implies (one p: Patient | p = a.aTarget)
}

// ─────────────────────────────────────────────────────────────────────────────
// ENDED MEMBERSHIPS DO NOT GRANT ACCESS  (FR-006 fail-closed semantics)
// ─────────────────────────────────────────────────────────────────────────────

fact F_EndedMembershipBlocksAccess {
  all m: CareTeamMembership |
    m.mstatus = Ended implies
      (no a: AccessAttempt |
        a.aCaller = m.member and a.aTarget = m.carePatient and a.aOutcome = Permitted)
}

// ─────────────────────────────────────────────────────────────────────────────
// OUTCOME-BASIS CONSISTENCY  (data-model.md AuthorisationBasis enum; FR-009)
// ─────────────────────────────────────────────────────────────────────────────

fact F_OutcomeBasisConsistency {
  all ae: AuditEntry | {
    ae.aOutcome = Permitted        implies ae.aBasis = CareTeamMemberBasis
    ae.aOutcome = Denied           implies ae.aBasis = NotCareTeamMemberBasis
    ae.aOutcome = NotFoundOrDenied implies ae.aBasis = PatientNotFoundBasis
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RESPONSE SHAPE MAPPING  (FR-007, SC-003 — byte-equivalent not-found)
// Denied and NotFoundOrDenied BOTH map to NotFoundShape (indistinguishable to caller).
// ─────────────────────────────────────────────────────────────────────────────

fact F_ResponseShapeMapping {
  all a: AccessAttempt | {
    a.aOutcome = Permitted implies a.aResponse = OkShape
    (a.aOutcome = Denied or a.aOutcome = NotFoundOrDenied) implies a.aResponse = NotFoundShape
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AUDIT COMPLETENESS  (FR-008, FR-013, SC-001, SC-002)
// Every RecordsLookup attempt → exactly one AuditEntry.
// AuditSearch attempts → no patient-level audit entry.
// ─────────────────────────────────────────────────────────────────────────────

fact F_AuditCompleteness {
  all a: AccessAttempt |
    a.aKind = RecordsLookup implies (one ae: AuditEntry | a.aAudit = ae)
  all a: AccessAttempt |
    a.aKind = AuditSearch implies no a.aAudit
}

// ─────────────────────────────────────────────────────────────────────────────
// AUDIT ENTRY UNIQUENESS — each AuditEntry owned by exactly one attempt
// (supports the append-only / no-mutation structural claim)
// ─────────────────────────────────────────────────────────────────────────────

fact F_AuditEntryUniqueness {
  all ae: AuditEntry | one a: AccessAttempt | a.aAudit = ae
}

// ─────────────────────────────────────────────────────────────────────────────
// APPEND-ONLY AUDIT ENTRIES  (FR-010, FR-012, SC-006)
// No two distinct AccessAttempts share the same AuditEntry
// (sharing would mean an entry was mutated / reused across operations).
// ─────────────────────────────────────────────────────────────────────────────

fact F_AppendOnlyAuditEntries {
  all disj a1, a2: AccessAttempt |
    (some a1.aAudit and some a2.aAudit) implies a1.aAudit != a2.aAudit
}

// ─────────────────────────────────────────────────────────────────────────────
// ATTRIBUTION CORRECTNESS  (FR-009 snapshot semantics)
// The audit entry records the actual caller and their role at access time.
// ─────────────────────────────────────────────────────────────────────────────

fact F_AttributionCorrectness {
  all a: AccessAttempt | all ae: AuditEntry |
    a.aAudit = ae implies {
      ae.aClinician    = a.aCaller
      ae.aSnapshotRole = a.aCaller.role
      ae.aPatient      = a.aTarget
      ae.aOutcome      = a.aOutcome
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// PREDICATES AND ASSERTIONS
// ═════════════════════════════════════════════════════════════════════════════

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-006
pred LeastPrivilege {
  some AccessAttempt
  all a: AccessAttempt | (a.aCaller.role -> a.aKind) in PermMatrix.Allowed
  // AuditOfficer cannot reach RecordsLookup
  no a: AccessAttempt | a.aCaller.role = AuditOfficer and a.aKind = RecordsLookup
  // Clinical roles cannot reach AuditSearch
  no a: AccessAttempt | isClinicalRole[a.aCaller.role] and a.aKind = AuditSearch
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables
pred PermissionCompleteness {
  // The Allowed relation is exactly the documented set — no undefined cells
  some AccessAttempt
  PermMatrix.Allowed =
    (Doctor       -> RecordsLookup) +
    (Nurse        -> RecordsLookup) +
    (Pharmacist   -> RecordsLookup) +
    (ClinicalAdmin -> RecordsLookup) +
    (AuditOfficer -> AuditSearch)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  // Every AccessAttempt (post-authentication) has exactly one resolved caller
  some AccessAttempt
  all a: AccessAttempt | one a.aCaller
  // No AccessAttempt can exist without the caller having a defined role
  all a: AccessAttempt | one a.aCaller.role
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, FR-009; data-model.md AuditEntry; SC-001
pred AuditCompleteness {
  some a: AccessAttempt | a.aKind = RecordsLookup
  all a: AccessAttempt |
    a.aKind = RecordsLookup implies (one ae: AuditEntry | a.aAudit = ae)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, FR-012, SC-006; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  some AuditEntry
  // No two distinct RecordsLookup attempts share an AuditEntry
  all disj a1, a2: AccessAttempt |
    (some a1.aAudit and some a2.aAudit) implies a1.aAudit != a2.aAudit
  // Every extant AuditEntry traces to exactly one attempt
  all ae: AuditEntry | one a: AccessAttempt | a.aAudit = ae
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md AuditEntry snapshot fields
pred AttributionCorrectness {
  some AccessAttempt
  all a: AccessAttempt | all ae: AuditEntry |
    a.aAudit = ae implies {
      ae.aClinician    = a.aCaller
      ae.aSnapshotRole = a.aCaller.role
    }
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006, SC-010; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  some a: AccessAttempt | a.aKind = RecordsLookup and a.aOutcome = Permitted
  all a: AccessAttempt |
    (a.aKind = RecordsLookup and a.aOutcome = Permitted) implies
      (some m: CareTeamMembership |
        m.member = a.aCaller and m.carePatient = a.aTarget and m.mstatus = Active)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003, SC-011; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
  // Both "denied" and "not-found" produce the same externally-visible shape
  some a: AccessAttempt | a.aOutcome = Denied
  some a: AccessAttempt | a.aOutcome = NotFoundOrDenied
  all a: AccessAttempt |
    (a.aOutcome = Denied or a.aOutcome = NotFoundOrDenied) implies a.aResponse = NotFoundShape
  // Permitted is the only path to OkShape
  all a: AccessAttempt | a.aResponse = OkShape implies a.aOutcome = Permitted
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC PREDICATES  (FR-NNN coverage)
// ─────────────────────────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some AccessAttempt
  all a: AccessAttempt | one a.aCaller
  all a: AccessAttempt | one a.aCaller.role
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002; data-model.md ClinicianRole enum
pred FR_002_RoleFromIdentityContext {
  // Snapshot role in the audit entry always matches the caller's actual role
  // (role is read from the identity context, never from the request payload)
  some AccessAttempt
  all a: AccessAttempt | all ae: AuditEntry |
    a.aAudit = ae implies ae.aSnapshotRole = a.aCaller.role
}
assert FR_002_RoleFromIdentityContext { FR_002_RoleFromIdentityContext }
check FR_002_RoleFromIdentityContext for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005 (read-only scope, Q2 = A)
pred FR_005_ReadOnlyAccess {
  some AccessAttempt
  // Only the two read-side operations exist in v1
  all a: AccessAttempt | a.aKind in (RecordsLookup + AuditSearch)
}
assert FR_005_ReadOnlyAccess { FR_005_ReadOnlyAccess }
check FR_005_ReadOnlyAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006, SC-010 (care-team-membership gating, Q3 = A)
pred FR_006_CareTeamMembershipGating {
  some a: AccessAttempt | a.aKind = RecordsLookup and a.aOutcome = Permitted
  all a: AccessAttempt |
    (a.aKind = RecordsLookup and a.aOutcome = Permitted) implies
      (some m: CareTeamMembership |
        m.member = a.aCaller and m.carePatient = a.aTarget and m.mstatus = Active)
  // Conversely: ended membership cannot produce Permitted
  all m: CareTeamMembership |
    m.mstatus = Ended implies
      (no a: AccessAttempt |
        a.aCaller = m.member and a.aTarget = m.carePatient and a.aOutcome = Permitted)
}
assert FR_006_CareTeamMembershipGating { FR_006_CareTeamMembershipGating }
check FR_006_CareTeamMembershipGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007, SC-003 (byte-equivalent denied / not-found)
pred FR_007_ByteEquivalentDenied {
  some a: AccessAttempt | a.aOutcome = Denied
  some a: AccessAttempt | a.aOutcome = NotFoundOrDenied
  all a: AccessAttempt |
    a.aOutcome = Denied implies a.aResponse = NotFoundShape
  all a: AccessAttempt |
    a.aOutcome = NotFoundOrDenied implies a.aResponse = NotFoundShape
}
assert FR_007_ByteEquivalentDenied { FR_007_ByteEquivalentDenied }
check FR_007_ByteEquivalentDenied for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008, SC-001, SC-002 (always-on audit for clinical endpoint)
pred FR_008_AlwaysOnAudit {
  some a: AccessAttempt | a.aKind = RecordsLookup
  all a: AccessAttempt |
    a.aKind = RecordsLookup implies (one ae: AuditEntry | a.aAudit = ae)
}
assert FR_008_AlwaysOnAudit { FR_008_AlwaysOnAudit }
check FR_008_AlwaysOnAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 (audit entry field completeness)
pred FR_009_AuditEntryFields {
  some AuditEntry
  all ae: AuditEntry | {
    one ae.aClinician
    one ae.aSnapshotRole
    one ae.aOutcome
    one ae.aBasis
  }
  // Snapshot role is consistent with the linked attempt's caller role
  all a: AccessAttempt | all ae: AuditEntry |
    a.aAudit = ae implies {
      ae.aClinician    = a.aCaller
      ae.aSnapshotRole = a.aCaller.role
      ae.aOutcome      = a.aOutcome
    }
}
assert FR_009_AuditEntryFields { FR_009_AuditEntryFields }
check FR_009_AuditEntryFields for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010, SC-006 (audit immutability — no UPDATE/DELETE)
pred FR_010_AuditImmutability {
  some AuditEntry
  // Each AuditEntry is associated with at most one AccessAttempt
  // (an entry "updated" by a second attempt would appear twice, violating this)
  all ae: AuditEntry | lone a: AccessAttempt | a.aAudit = ae
  // No two distinct attempts share an audit entry
  all disj a1, a2: AccessAttempt |
    (some a1.aAudit and some a2.aAudit) implies a1.aAudit != a2.aAudit
}
assert FR_010_AuditImmutability { FR_010_AuditImmutability }
check FR_010_AuditImmutability for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011, SC-011 (audit-search endpoint: IG-only; existence hidden from clinical roles)
pred FR_011_AuditSearchIGOnly {
  some AccessAttempt
  // Only AuditOfficer may call AuditSearch
  all a: AccessAttempt | a.aKind = AuditSearch implies a.aCaller.role = AuditOfficer
  // Clinical roles never call AuditSearch (endpoint existence not leaked)
  all a: AccessAttempt | isClinicalRole[a.aCaller.role] implies a.aKind != AuditSearch
  // AuditSearch produces no patient-level audit entry
  all a: AccessAttempt | a.aKind = AuditSearch implies no a.aAudit
}
assert FR_011_AuditSearchIGOnly { FR_011_AuditSearchIGOnly }
check FR_011_AuditSearchIGOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012, SC-006 (8-year retention floor — no delete path)
// Structural encoding: every AuditEntry that exists persists (no "deleted" entries modelled)
pred FR_012_RetentionFloor {
  // All AuditEntries in the model are live: each is reachable via exactly one attempt
  some AuditEntry
  all ae: AuditEntry | one a: AccessAttempt | a.aAudit = ae
}
assert FR_012_RetentionFloor { FR_012_RetentionFloor }
check FR_012_RetentionFloor for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013, SC-002, SC-007 (no record observed without matching audit)
pred FR_013_NoRecordWithoutAudit {
  some a: AccessAttempt | a.aOutcome = Permitted
  all a: AccessAttempt |
    a.aOutcome = Permitted implies (one ae: AuditEntry | a.aAudit = ae)
  // OkShape is only returned when a matching audit entry exists
  all a: AccessAttempt |
    a.aResponse = OkShape implies (one ae: AuditEntry | a.aAudit = ae)
}
assert FR_013_NoRecordWithoutAudit { FR_013_NoRecordWithoutAudit }
check FR_013_NoRecordWithoutAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014, FR-015, SC-008 (clinical-safety fields in every permitted response)
// Structural encoding: OkShape (the only shape returned for Permitted) implies Permitted outcome,
// meaning the full patient summary (including allergies, warnings, patient_id, DoB) was assembled.
pred FR_014_FR_015_ClinicalSafetyFields {
  some a: AccessAttempt | a.aResponse = OkShape
  // OkShape ↔ Permitted (bidirectional — no Permitted without OkShape, no OkShape without Permitted)
  all a: AccessAttempt | a.aResponse = OkShape iff a.aOutcome = Permitted
}
assert FR_014_FR_015_ClinicalSafetyFields { FR_014_FR_015_ClinicalSafetyFields }
check FR_014_FR_015_ClinicalSafetyFields for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_CareTeamViolation { some a: AccessAttempt | a.aKind = RecordsLookup and a.aOutcome = Permitted and (no m: CareTeamMembership | m.member = a.aCaller and m.carePatient = a.aTarget and m.mstatus = Active) }
