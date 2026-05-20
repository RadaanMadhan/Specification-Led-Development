// === feature_model.als — Alloy model for Clinician Access to Patient Medical Records (C-L1) ===
// Feature folder: C-L1  (branch 009-clinician-record-access, spec v1 2026-05-17)
// Encodes invariants from spec.md, data-model.md, and contracts/http-api.md

// ─────────────────────────────────────────────────────────────────────────────
// ROLES AND OPERATIONS
// ─────────────────────────────────────────────────────────────────────────────

abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends Role {}

abstract sig OperationKind {}
one sig RecordsLookup, AuditSearch extends OperationKind {}

// Permission matrix as a singleton-sig field (canonical pattern from system prompt).
// Reference cells with `Role -> OperationKind in PermMatrix.Allowed`.
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─────────────────────────────────────────────────────────────────────────────
// ENUMERATIONS
// ─────────────────────────────────────────────────────────────────────────────

abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

abstract sig AuthorisationBasis {}
one sig CareTeamMemberBasis, NotCareTeamMemberBasis, PatientNotFoundBasis extends AuthorisationBasis {}

// Observable response shape presented to the caller: 200 OK vs byte-equivalent 404.
abstract sig ObservableResponse {}
one sig OkResponse, NotFoundResponse extends ObservableResponse {}

// ─────────────────────────────────────────────────────────────────────────────
// DOMAIN ENTITIES  (dynamic sigs — referenced in F_NonEmptyUniverse)
// ─────────────────────────────────────────────────────────────────────────────

// An opaque patient identifier as supplied in a request body.
// Not every PatientRef corresponds to a real Patient (FR-008: we still audit
// when the patient does not exist in the system).
sig PatientRef {}

// A real Patient stored in the system, uniquely identified by a PatientRef.
sig Patient { pid: one PatientRef }

// An authenticated principal (clinician or audit/IG officer).  Every User
// carries exactly one Role — taken from the host-product identity context (FR-002).
sig User { role: one Role }

// Host-product assertion that a clinician is on a patient's active care team.
sig CareTeamMembership {
    clinician : one User,
    patient   : one Patient,
    status    : one MembershipStatus
}

// Immutable append-only record of one access attempt (FR-009, FR-010).
sig AuditEntry {
    clinician             : one User,
    clinicianRoleSnapshot : one Role,   // snapshotted at time of access — not live (FR-009)
    patientRef            : one PatientRef, // as presented; no FK constraint (FR-008)
    outcome               : one AccessOutcome,
    authBasis             : one AuthorisationBasis
}

// An authenticated access operation modelled as one atomic transaction.
sig Operation {
    caller           : one User,
    kind             : one OperationKind,
    targetRef        : one PatientRef,
    outcome          : one AccessOutcome,
    observedResponse : one ObservableResponse,
    audit            : one AuditEntry    // FR-008, FR-013: always exactly one per operation
}

// ─────────────────────────────────────────────────────────────────────────────
// NON-EMPTY UNIVERSE (rule 9 — force dynamic sigs to have ≥ 1 atom)
// ─────────────────────────────────────────────────────────────────────────────

fact F_NonEmptyUniverse {
    some User
    some Patient
    some PatientRef
    some CareTeamMembership
    some AuditEntry
    some Operation
}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSION MATRIX  (contracts/http-api.md authorization tables)
// ─────────────────────────────────────────────────────────────────────────────

fact F_PermissionMatrix {
    // Clinical roles may call RecordsLookup (FR-006); AuditOfficer may not.
    // AuditOfficer may call AuditSearch (FR-011); no clinical role may.
    PermMatrix.Allowed =
        (Doctor        -> RecordsLookup) +
        (Nurse         -> RecordsLookup) +
        (Pharmacist    -> RecordsLookup) +
        (ClinicalAdmin -> RecordsLookup) +
        (AuditOfficer  -> AuditSearch)
}

// ─────────────────────────────────────────────────────────────────────────────
// STRUCTURAL INTEGRITY FACTS
// ─────────────────────────────────────────────────────────────────────────────

// Each real Patient has a globally unique pid (data-model.md PK on patients.id).
fact F_PatientPidUnique {
    all disj p1, p2: Patient | p1.pid != p2.pid
}

// Every operation is within the caller's permitted role × kind cell
// (operations that violate the matrix are impossible — LeastPrivilege base).
fact F_OperationWithinPermittedRoles {
    all op: Operation | op.caller.role -> op.kind in PermMatrix.Allowed
}

// ─── Audit attribution facts (FR-009) ────────────────────────────────────────

// The audit entry's clinician field is the operation's caller.
fact F_AuditClinicianAttribution {
    all op: Operation | op.audit.clinician = op.caller
}

// The role snapshot in the audit entry is the caller's role AT THE TIME of the
// operation (snapshot semantics — renames do not retroactively mutate entries).
fact F_AuditRoleSnapshotCorrect {
    all op: Operation | op.audit.clinicianRoleSnapshot = op.caller.role
}

// The audit entry's patientRef matches the targetRef presented in the request.
fact F_AuditPatientRefCorrect {
    all op: Operation | op.audit.patientRef = op.targetRef
}

// The audit entry's outcome matches the operation's outcome.
fact F_AuditOutcomeConsistent {
    all op: Operation | op.audit.outcome = op.outcome
}

// Authorisation-basis is determined by the outcome (FR-009 field semantics):
//   Permitted → care_team_member
//   Denied → not_care_team_member
//   NotFoundOrDenied → patient_not_found
fact F_AuthBasisConsistency {
    all op: Operation {
        op.outcome = Permitted         implies op.audit.authBasis = CareTeamMemberBasis
        op.outcome = Denied            implies op.audit.authBasis = NotCareTeamMemberBasis
        op.outcome = NotFoundOrDenied  implies op.audit.authBasis = PatientNotFoundBasis
    }
}

// ─── Audit one-to-one and append-only facts (FR-008, FR-010) ─────────────────

// Every AuditEntry belongs to exactly one Operation (no orphan entries, SC-002).
fact F_AuditOneToOne {
    all ae: AuditEntry | one op: Operation | op.audit = ae
}

// Append-only: two distinct Operations never share an AuditEntry (structural
// analog of "no UPDATE/DELETE on audit_entries" — FR-010, data-model.md).
fact F_AppendOnlyAuditEntries {
    all disj op1, op2: Operation | op1.audit != op2.audit
}

// ─── Care-team gating facts (FR-006) ─────────────────────────────────────────

// RecordsLookup outcome is determined by care-team membership and patient existence.
fact F_CareTeamGating {
    all op: Operation | op.kind = RecordsLookup implies {
        // Only clinical roles (i.e., not AuditOfficer) may reach this endpoint.
        op.caller.role != AuditOfficer
        // Permitted iff the target patient exists AND the caller has an active membership.
        op.outcome = Permitted implies (
            some p: Patient | p.pid = op.targetRef and
            (some m: CareTeamMembership |
                m.clinician = op.caller and m.patient = p and m.status = Active)
        )
        // Denied iff the patient exists but the caller has no active membership.
        op.outcome = Denied implies (
            (some p: Patient | p.pid = op.targetRef) and
            (no m: CareTeamMembership |
                m.clinician = op.caller and
                (some p: Patient | p.pid = op.targetRef and m.patient = p) and
                m.status = Active)
        )
        // NotFoundOrDenied iff no real Patient corresponds to the targetRef.
        op.outcome = NotFoundOrDenied implies (
            no p: Patient | p.pid = op.targetRef
        )
    }
}

// Only AuditOfficer callers may execute AuditSearch operations (FR-011, SC-011).
fact F_AuditSearchRoleGating {
    all op: Operation | op.kind = AuditSearch implies op.caller.role = AuditOfficer
}

// ─── No information leakage fact (FR-007) ────────────────────────────────────

// The externally observable response for Denied and NotFoundOrDenied is
// byte-identical (single canonical not_found response — SC-003).
fact F_NoInformationLeakageFact { /* MUTATED — body cleared by validator */ }

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN PREDICATES + ASSERTIONS
// ─────────────────────────────────────────────────────────────────────────────

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorization tables; spec.md FR-006, FR-011
pred LeastPrivilege {
    some Operation
    // AuditOfficer cannot execute RecordsLookup under any outcome.
    no op: Operation | op.caller.role = AuditOfficer and op.kind = RecordsLookup
    // Clinical roles cannot execute AuditSearch.
    no op: Operation |
        (op.caller.role = Doctor or op.caller.role = Nurse or
         op.caller.role = Pharmacist or op.caller.role = ClinicalAdmin) and
        op.kind = AuditSearch
    // Every permitted operation is within the permission matrix.
    all op: Operation | op.caller.role -> op.kind in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md authorization tables
pred PermissionCompleteness {
    // Every (Role × OperationKind) cell has a determinate verdict:
    // the Allowed relation is exactly the set declared — no undefined cells.
    some r: Role, o: OperationKind |
        (r -> o in PermMatrix.Allowed or r -> o not in PermMatrix.Allowed)
    // Specifically: the five allowed cells and only those five exist.
    Doctor        -> RecordsLookup in PermMatrix.Allowed
    Nurse         -> RecordsLookup in PermMatrix.Allowed
    Pharmacist    -> RecordsLookup in PermMatrix.Allowed
    ClinicalAdmin -> RecordsLookup in PermMatrix.Allowed
    AuditOfficer  -> AuditSearch   in PermMatrix.Allowed
    AuditOfficer  -> RecordsLookup not in PermMatrix.Allowed
    Doctor        -> AuditSearch   not in PermMatrix.Allowed
    Nurse         -> AuditSearch   not in PermMatrix.Allowed
    Pharmacist    -> AuditSearch   not in PermMatrix.Allowed
    ClinicalAdmin -> AuditSearch   not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
    some Operation
    // Every operation in scope has a resolved authenticated caller with a known role.
    all op: Operation | one op.caller and one op.caller.role
    // No unauthenticated operation carries an audit entry that references a null clinician.
    all ae: AuditEntry | one ae.clinician
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, FR-009; data-model.md append-only audit_entries
pred AuditCompleteness {
    some Operation
    // Every operation has exactly one audit entry linked to it.
    all op: Operation | one op.audit
    // No AuditEntry is orphaned — every entry is owned by exactly one operation.
    all ae: AuditEntry | (one op: Operation | op.audit = ae)
    // Two distinct operations never share an audit entry (no duplicates, SC-002).
    all disj op1, op2: Operation | op1.audit != op2.audit
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, SC-006; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
    some AuditEntry
    // Structural encoding: two distinct operations never share an entry
    // (sharing would model an in-place mutation of a prior entry).
    all disj op1, op2: Operation | op1.audit != op2.audit
    // Every AuditEntry atom is owned by at most one Operation (no re-use / overwrite).
    all ae: AuditEntry | lone op: Operation | op.audit = ae
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md AuditEntry.clinician_display_name snapshot
pred AttributionCorrectness {
    some Operation
    // The clinician recorded in the audit entry is the operation's actual caller.
    all op: Operation | op.audit.clinician = op.caller
    // The role recorded is the caller's role at the time of the operation (snapshot).
    all op: Operation | op.audit.clinicianRoleSnapshot = op.caller.role
    // The patientRef in the audit entry is the identifier presented in the request.
    all op: Operation | op.audit.patientRef = op.targetRef
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
    some op: Operation | op.kind = RecordsLookup and op.outcome = Permitted
    // A Permitted outcome on RecordsLookup requires an active care-team membership.
    all op: Operation |
        (op.kind = RecordsLookup and op.outcome = Permitted) implies
        (some p: Patient | p.pid = op.targetRef and
         (some m: CareTeamMembership |
             m.clinician = op.caller and m.patient = p and m.status = Active))
    // A caller without active membership cannot receive a Permitted outcome.
    all op: Operation |
        (op.kind = RecordsLookup and
         (no m: CareTeamMembership |
             m.clinician = op.caller and
             (some p: Patient | p.pid = op.targetRef and m.patient = p) and
             m.status = Active)) implies
        op.outcome != Permitted
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003, SC-011; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
    some op: Operation | op.outcome = Denied
    some op: Operation | op.outcome = NotFoundOrDenied
    // Denied and NotFoundOrDenied both produce the byte-equivalent not-found response.
    all op: Operation |
        (op.outcome = Denied or op.outcome = NotFoundOrDenied) implies
        op.observedResponse = NotFoundResponse
    // Permitted produces an OkResponse — the two branches are distinguishable only
    // by the callers authorised to receive them.
    all op: Operation |
        op.outcome = Permitted implies op.observedResponse = OkResponse
    // No RecordsLookup response distinguishes "patient does not exist" from
    // "patient exists but caller is not on care team".
    all disj op1, op2: Operation |
        (op1.kind = RecordsLookup and op1.outcome = Denied and
         op2.kind = RecordsLookup and op2.outcome = NotFoundOrDenied) implies
        op1.observedResponse = op2.observedResponse
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// ─────────────────────────────────────────────────────────────────────────────
// FEATURE-SPECIFIC PREDICATES + ASSERTIONS (per FR-NNN)
// ─────────────────────────────────────────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001 — authentication required; no audit before auth boundary
pred FR_001_AuthRequired {
    some Operation
    // Every operation has a caller with a resolved, single role.
    all op: Operation | one op.caller.role
    // AuditEntry always records a real User — no anonymous entries.
    all ae: AuditEntry | ae.clinician in User
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 — clinician_role resolved from identity context; exactly one role per user
pred FR_002_RoleResolution {
    some User
    // Every User has exactly one Role from the v1 catalogue.
    all u: User | one u.role
    all u: User | u.role in (Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin)
}
assert FR_002_RoleResolution { FR_002_RoleResolution }
check FR_002_RoleResolution for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 — care-team membership gates every RecordsLookup; fail-closed
pred FR_006_CareTeamGating {
    some op: Operation | op.kind = RecordsLookup
    // Permitted outcome requires active membership.
    all op: Operation |
        (op.kind = RecordsLookup and op.outcome = Permitted) implies
        (some p: Patient | p.pid = op.targetRef and
         (some m: CareTeamMembership |
             m.clinician = op.caller and m.patient = p and m.status = Active))
    // AuditOfficer is excluded from RecordsLookup (no care-team path for IG role).
    no op: Operation | op.kind = RecordsLookup and op.caller.role = AuditOfficer
    // Ended (inactive) memberships do not authorise access.
    all op: Operation |
        (op.kind = RecordsLookup and
         (all m: CareTeamMembership |
             (some p: Patient | p.pid = op.targetRef and m.patient = p and
              m.clinician = op.caller) implies m.status = Ended)) implies
        op.outcome != Permitted
}
assert FR_006_CareTeamGating { FR_006_CareTeamGating }
check FR_006_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007, SC-003 — denied response is byte-equivalent to not-found
pred FR_007_ByteEquivalentDenyNotFound {
    some op: Operation | op.outcome = Denied
    some op: Operation | op.outcome = NotFoundOrDenied
    // Both map to the same ObservableResponse atom.
    all op: Operation |
        op.outcome = Denied implies op.observedResponse = NotFoundResponse
    all op: Operation |
        op.outcome = NotFoundOrDenied implies op.observedResponse = NotFoundResponse
    // Permitted maps to a different ObservableResponse atom.
    all op: Operation |
        op.outcome = Permitted implies op.observedResponse = OkResponse
    OkResponse != NotFoundResponse
}
assert FR_007_ByteEquivalentDenyNotFound { FR_007_ByteEquivalentDenyNotFound }
check FR_007_ByteEquivalentDenyNotFound for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008, SC-001, SC-002 — every access attempt produces exactly one audit entry
pred FR_008_AlwaysAudit {
    some Operation
    // Every operation has exactly one audit entry.
    all op: Operation | one op.audit
    // Every audit entry corresponds to exactly one operation.
    all ae: AuditEntry | one op: Operation | op.audit = ae
    // No audit entry is orphaned.
    AuditEntry = Operation.audit
}
assert FR_008_AlwaysAudit { FR_008_AlwaysAudit }
check FR_008_AlwaysAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 — every audit entry shape (all required fields populated)
pred FR_009_AuditEntryShape {
    some AuditEntry
    // Every audit entry has a clinician, a role snapshot, a patientRef, an outcome, and a basis.
    all ae: AuditEntry {
        one ae.clinician
        one ae.clinicianRoleSnapshot
        one ae.patientRef
        one ae.outcome
        one ae.authBasis
    }
    // Role snapshot is always a valid v1 catalogue role.
    all ae: AuditEntry |
        ae.clinicianRoleSnapshot in
            (Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin)
    // Outcome is one of the three permitted values.
    all ae: AuditEntry |
        ae.outcome in (Permitted + Denied + NotFoundOrDenied)
    // AuthBasis is consistent with outcome.
    all ae: AuditEntry {
        ae.outcome = Permitted         implies ae.authBasis = CareTeamMemberBasis
        ae.outcome = Denied            implies ae.authBasis = NotCareTeamMemberBasis
        ae.outcome = NotFoundOrDenied  implies ae.authBasis = PatientNotFoundBasis
    }
}
assert FR_009_AuditEntryShape { FR_009_AuditEntryShape }
check FR_009_AuditEntryShape for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010, SC-006 — audit entries are immutable; no update or delete path
pred FR_010_AuditImmutable {
    some AuditEntry
    // Structural encoding: no two distinct operations share an AuditEntry
    // (sharing would model an overwrite — the only mutation possible in this abstract model).
    all disj op1, op2: Operation | op1.audit != op2.audit
    // Each AuditEntry atom is owned by at most one Operation (no reuse).
    all ae: AuditEntry | lone op: Operation | op.audit = ae
}
assert FR_010_AuditImmutable { FR_010_AuditImmutable }
check FR_010_AuditImmutable for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011, SC-011 — AuditSearch is exclusively for audit_officer; hidden from clinical roles
pred FR_011_AuditOfficerOnly {
    some op: Operation | op.kind = AuditSearch
    // Every AuditSearch operation is performed by an AuditOfficer.
    all op: Operation | op.kind = AuditSearch implies op.caller.role = AuditOfficer
    // No clinical role can execute AuditSearch.
    no op: Operation |
        op.kind = AuditSearch and
        op.caller.role in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
    // Non-audit-officer callers receive the byte-equivalent not-found response
    // (the endpoint's existence does not leak — SC-011).
    // Modelled: any operation by a non-AuditOfficer for AuditSearch is structurally
    // impossible (prevented by LeastPrivilege), so no ObservableResponse = OkResponse
    // can be produced by a non-AuditOfficer on AuditSearch.
    no op: Operation |
        op.kind = AuditSearch and
        op.caller.role != AuditOfficer and
        op.observedResponse = OkResponse
}
assert FR_011_AuditOfficerOnly { FR_011_AuditOfficerOnly }
check FR_011_AuditOfficerOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013, SC-007 — no permitted record view without a committed audit entry
pred FR_013_AuditBeforeAccess {
    some op: Operation | op.outcome = Permitted
    // Every permitted operation has a committed audit entry (one-to-one, already owned).
    all op: Operation |
        op.outcome = Permitted implies (one op.audit and op.audit.outcome = Permitted)
    // The audit entry's clinician matches the caller (the audit was written for THIS operation).
    all op: Operation |
        op.outcome = Permitted implies op.audit.clinician = op.caller
}
assert FR_013_AuditBeforeAccess { FR_013_AuditBeforeAccess }
check FR_013_AuditBeforeAccess for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_LeakageViolation { some op: Operation | op.outcome = Denied and op.observedResponse = OkResponse }
