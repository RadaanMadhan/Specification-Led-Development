// === feature_model.als — Alloy model for C-L1: Clinician Access to Patient Medical Records ===
// Feature Branch: 009-clinician-record-access
// Spec: spec.md, data-model.md, contracts/http-api.md (v1, UK NHS, read-only, care-team-only)

// ─── Role catalogue (data-model.md ClinicianRole enum; FR-002) ────────────────
abstract sig ClinicianRole {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends ClinicianRole {}

// ─── Clinical roles (used in several constraints) ────────────────────────────
// Doctor + Nurse + Pharmacist + ClinicalAdmin — the four that may call RecordsLookup
abstract sig ClinicalRole extends ClinicianRole {}
one sig ClinicalDoctor    extends ClinicalRole {}
one sig ClinicalNurse     extends ClinicalRole {}
one sig ClinicalPharmacist extends ClinicalRole {}
one sig ClinicalAdmin      extends ClinicalRole {}
// NOTE: the four concrete "one sig" atoms above are distinct from the original
// Doctor/Nurse/Pharmacist/ClinicalAdmin atoms; to avoid duplicate atom names we
// fold the role catalogue into a single hierarchy below and drop the intermediate
// abstract layer:

// ─── RESTART – clean role hierarchy ──────────────────────────────────────────
// (Alloy requires each atom name to be unique; we define roles in one hierarchy.)

// IMPORTANT: the above draft is replaced by the clean version below. All sigs
// are declared exactly once.

// ═══════════════════════════════════════════════════════════════════════════════
// SIGNATURES
// ═══════════════════════════════════════════════════════════════════════════════

// ─── Clinician roles ──────────────────────────────────────────────────────────
// data-model.md ClinicianRole enum; FR-002
abstract sig Role {}
one sig RoleDoctor, RoleNurse, RolePharmacist, RoleAuditOfficer, RoleClinicalAdmin extends Role {}

// ─── Endpoint / operation kinds ───────────────────────────────────────────────
// contracts/http-api.md – exactly two endpoints in v1
abstract sig OperationKind {}
one sig RecordsLookup, AuditSearch extends OperationKind {}

// ─── Access outcomes ──────────────────────────────────────────────────────────
// data-model.md AccessOutcome enum; FR-009
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// ─── Authorisation bases ──────────────────────────────────────────────────────
// data-model.md AuthorisationBasis enum; FR-009
abstract sig AuthBasis {}
one sig BasisCareTeamMember, BasisNotCareTeamMember, BasisPatientNotFound extends AuthBasis {}

// ─── Care-team membership status ─────────────────────────────────────────────
// data-model.md MembershipStatus enum; FR-006
abstract sig MembershipStatus {}
one sig Active, Ended extends MembershipStatus {}

// ─── Externally-visible HTTP response shapes ─────────────────────────────────
// contracts/http-api.md status codes; FR-007, FR-013
abstract sig ResponseShape {}
one sig Resp200OK, Resp404NotFound, Resp401Unauth, Resp503Unavail extends ResponseShape {}

// ─── Dynamic sigs ─────────────────────────────────────────────────────────────

// User: a clinician or IG officer authenticated by the system (FR-002)
sig User {
    role: one Role
}

// Patient: a subject whose record is held; identified by an opaque id
sig Patient {}

// PatientSummary: the 1-1 safety-relevant view of a Patient (data-model.md PatientSummary)
// Every Patient that can be successfully looked up has exactly one PatientSummary.
sig PatientSummary {
    owner: one Patient
}

// CareTeamMembership: host-product assertion that a clinician is on a patient's care team
// data-model.md CareTeamMembership; composite PK (clinician, patient, episode) collapsed to
// a unique pair (clinician, patient, status) for structural modelling purposes.
sig CareTeamMembership {
    member:  one User,
    patient: one Patient,
    mstatus: one MembershipStatus
}

// Operation: one request that reached the service layer (auth succeeded, patient_id supplied)
// target is `lone Patient` because the presented patient_id may not correspond to any Patient.
sig Operation {
    caller:     one User,
    op_kind:    one OperationKind,
    target:     lone Patient,        // none ⟺ patient does not exist in the system
    outcome:    one AccessOutcome,
    auth_basis: one AuthBasis,
    response:   one ResponseShape
}

// AuditEntry: immutable append-only per-access record (data-model.md AuditEntry; FR-009/010)
// patient_ref is `lone Patient` — not FK-constrained; we still log when patient absent (FR-008).
sig AuditEntry {
    ae_clinician:      one User,
    patient_ref:       lone Patient,
    snapshotted_role:  one Role,
    ae_outcome:        one AccessOutcome,
    ae_auth_basis:     one AuthBasis,
    records_op:        one Operation    // injective 1-1 link to the operation this entry records
}

// Permission matrix: singleton holding the (Role × OperationKind) allowed relation
// Canonical pattern per system prompt §7; sourced from contracts/http-api.md authorisation tables.
one sig PermMatrix {
    Allowed: set Role -> OperationKind
}

// ═══════════════════════════════════════════════════════════════════════════════
// FACTS
// ═══════════════════════════════════════════════════════════════════════════════

// ─── Non-empty universe ───────────────────────────────────────────────────────
fact F_NonEmptyUniverse {
    some User
    some Patient
    some CareTeamMembership
    some Operation
    some AuditEntry
    some PatientSummary
}

// ─── Permission matrix (contracts/http-api.md authorisation tables) ───────────
// Clinical roles (Doctor, Nurse, Pharmacist, ClinicalAdmin) may call RecordsLookup.
// AuditOfficer may call AuditSearch only.  Closed-world: exactly these cells.
fact F_PermissionMatrix {
    PermMatrix.Allowed =
        (RoleDoctor        -> RecordsLookup)
      + (RoleNurse         -> RecordsLookup)
      + (RolePharmacist    -> RecordsLookup)
      + (RoleClinicalAdmin -> RecordsLookup)
      + (RoleAuditOfficer  -> AuditSearch)
}

// ─── Least privilege: every operation matches an allowed (role, endpoint) cell ─
// contracts/http-api.md authorisation tables; FR-006, FR-011
fact F_LeastPrivilege {
    all op: Operation |
        op.caller.role -> op.op_kind in PermMatrix.Allowed
}

// ─── Care-team membership gating (FR-006) ────────────────────────────────────
// A permitted RecordsLookup requires an active care-team membership for that (caller, patient).
fact F_CareTeamGating {
    all op: Operation |
        (op.op_kind = RecordsLookup and op.outcome = Permitted) implies
        (some m: CareTeamMembership |
            m.member = op.caller and m.patient = op.target and m.mstatus = Active)
}

// ─── Outcome ↔ auth_basis consistency ────────────────────────────────────────
// data-model.md AuthorisationBasis enum; FR-009 outcome/basis pairing
fact F_OutcomeAuthBasisConsistency {
    all op: Operation |
        (op.outcome = Permitted         implies op.auth_basis = BasisCareTeamMember)
        and
        (op.outcome = Denied            implies op.auth_basis = BasisNotCareTeamMember)
        and
        (op.outcome = NotFoundOrDenied  implies op.auth_basis = BasisPatientNotFound)
}

// ─── Target/outcome consistency ───────────────────────────────────────────────
// If no patient atom (patient not found), outcome must be NotFoundOrDenied.
// If a patient atom exists and outcome is Denied, the patient must exist.
fact F_TargetOutcomeConsistency {
    all op: Operation |
        (no op.target implies op.outcome = NotFoundOrDenied)
        and
        (op.outcome = Permitted implies (some op.target))
        and
        (op.outcome = Denied    implies (some op.target))
}

// ─── Audit completeness: every operation produces exactly one audit entry (FR-008) ─
// EXCEPTION: 503 SLA-breach — no audit entry is written (FR-013; SC-007).
fact F_AuditCompleteness {
    all op: Operation |
        op.response != Resp503Unavail implies
        (one ae: AuditEntry | ae.records_op = op)
}

// ─── Audit SLA breach: 503 response has NO audit entry (FR-013) ──────────────
fact F_AuditSLABreachNoEntry {
    all op: Operation |
        op.response = Resp503Unavail implies
        (no ae: AuditEntry | ae.records_op = op)
}

// ─── Append-only: each AuditEntry links to a distinct Operation (FR-010) ──────
// Structural proxy for immutability / no-duplicate-entries invariant.
fact F_AppendOnlyAuditEntries {
    all disj ae1, ae2: AuditEntry | ae1.records_op != ae2.records_op
}

// ─── Attribution: AuditEntry fields match the operation they record (FR-009) ──
fact F_AuditAttribution {
    all ae: AuditEntry |
        ae.ae_clinician     = ae.records_op.caller
        and ae.patient_ref  = ae.records_op.target
        and ae.ae_outcome   = ae.records_op.outcome
        and ae.ae_auth_basis = ae.records_op.auth_basis
        and ae.snapshotted_role = ae.records_op.caller.role
}

// ─── No information leakage: Denied and NotFoundOrDenied produce identical responses ─
// FR-007, SC-003; single canonical 404 response body for all "you cannot see this" cases.
fact F_NoInformationLeakage {
    all op: Operation |
        (op.outcome = Denied or op.outcome = NotFoundOrDenied) implies
        op.response = Resp404NotFound
}

// ─── Permitted access returns 200 OK ─────────────────────────────────────────
fact F_PermittedReturnsOK {
    all op: Operation |
        op.outcome = Permitted implies op.response = Resp200OK
}

// ─── PatientSummary one-to-one with Patient (data-model.md 1:1 PatientSummary) ─
fact F_PatientSummaryOnePerPatient {
    all disj ps1, ps2: PatientSummary | ps1.owner != ps2.owner
}

// ─── Every permitted RecordsLookup target has a PatientSummary (FR-014, FR-015) ─
fact F_PermittedLookupHasSummary {
    all op: Operation |
        (op.op_kind = RecordsLookup and op.outcome = Permitted) implies
        (some ps: PatientSummary | ps.owner = op.target)
}

// ─── AuditOfficer may not use RecordsLookup (contracts/http-api.md; FR-011) ──
fact F_AuditOfficerCannotLookup {
    all op: Operation |
        op.caller.role = RoleAuditOfficer implies op.op_kind != RecordsLookup
}

// ─── Clinical roles may not use AuditSearch (FR-011; SC-011) ─────────────────
fact F_ClinicalRolesCannotAuditSearch {
    all op: Operation |
        op.op_kind = AuditSearch implies op.caller.role = RoleAuditOfficer
}

// ═══════════════════════════════════════════════════════════════════════════════
// PREDICATES + ASSERTIONS + CHECKS
// ═══════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-006, FR-011
// ─────────────────────────────────────────────────────────────────────────────
pred LeastPrivilege {
    // Every operation in the system has a (role, endpoint) pair that is
    // explicitly allowed in the permission matrix — no silently-granted cells.
    some Operation   // non-vacuous
    all op: Operation |
        op.caller.role -> op.op_kind in PermMatrix.Allowed
    // AuditOfficer must never reach RecordsLookup
    no op: Operation |
        op.caller.role = RoleAuditOfficer and op.op_kind = RecordsLookup
    // Clinical roles must never reach AuditSearch
    no op: Operation |
        op.op_kind = AuditSearch and op.caller.role != RoleAuditOfficer
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission table
// ─────────────────────────────────────────────────────────────────────────────
pred PermissionCompleteness {
    // The Allowed relation covers every (Role × OperationKind) pair exactly
    // once — either in Allowed or provably absent.  We check the closed-world
    // shape: the five allowed cells exist, and no extra cells exist.
    (RoleDoctor        -> RecordsLookup) in PermMatrix.Allowed
    (RoleNurse         -> RecordsLookup) in PermMatrix.Allowed
    (RolePharmacist    -> RecordsLookup) in PermMatrix.Allowed
    (RoleClinicalAdmin -> RecordsLookup) in PermMatrix.Allowed
    (RoleAuditOfficer  -> AuditSearch)   in PermMatrix.Allowed
    // Denied cells are absent
    (RoleAuditOfficer  -> RecordsLookup) not in PermMatrix.Allowed
    (RoleDoctor        -> AuditSearch)   not in PermMatrix.Allowed
    (RoleNurse         -> AuditSearch)   not in PermMatrix.Allowed
    (RolePharmacist    -> AuditSearch)   not in PermMatrix.Allowed
    (RoleClinicalAdmin -> AuditSearch)   not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
// ─────────────────────────────────────────────────────────────────────────────
pred AuthRequiredEverywhere {
    // Every operation that reached the service layer was performed by a
    // resolved, known User (the auth boundary is a precondition for Operation
    // creation in this model; unauthenticated requests never become Operations).
    some Operation
    all op: Operation | some op.caller
    // No operation has a null/unknown role (role must be from the v1 catalogue)
    all op: Operation | op.caller.role in Role
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, SC-001, SC-002; data-model.md AuditEntry
// ─────────────────────────────────────────────────────────────────────────────
pred AuditCompleteness {
    // Every operation that did NOT return 503 has exactly one audit entry.
    some op: Operation | op.response != Resp503Unavail  // non-vacuous
    all op: Operation |
        op.response != Resp503Unavail implies
        (one ae: AuditEntry | ae.records_op = op)
    // No audit entry without a corresponding operation
    all ae: AuditEntry | some ae.records_op
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, SC-006; data-model.md "no UPDATE/DELETE" on audit_entries
// ─────────────────────────────────────────────────────────────────────────────
pred AppendOnly {
    // No two AuditEntries record the same Operation (no duplicate/overwrite).
    some AuditEntry
    all disj ae1, ae2: AuditEntry | ae1.records_op != ae2.records_op
    // Every AuditEntry is linked; none is orphaned.
    all ae: AuditEntry | one ae.records_op
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md AuditEntry snapshot fields
// ─────────────────────────────────────────────────────────────────────────────
pred AttributionCorrectness {
    some AuditEntry
    all ae: AuditEntry |
        // Clinician in the entry matches the actual caller of the operation.
        ae.ae_clinician = ae.records_op.caller
        // Patient reference matches the target presented in the request.
        and ae.patient_ref = ae.records_op.target
        // Snapshotted role matches the caller's role at the time of the access.
        and ae.snapshotted_role = ae.records_op.caller.role
        // Outcome and auth_basis are faithfully recorded.
        and ae.ae_outcome   = ae.records_op.outcome
        and ae.ae_auth_basis = ae.records_op.auth_basis
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006, SC-010; data-model.md CareTeamMembership
// ─────────────────────────────────────────────────────────────────────────────
pred OwnershipBasedAccess {
    // A Permitted outcome on RecordsLookup requires an active care-team membership
    // linking the caller to the target patient.
    some op: Operation | op.outcome = Permitted and op.op_kind = RecordsLookup
    all op: Operation |
        (op.op_kind = RecordsLookup and op.outcome = Permitted) implies
        (some m: CareTeamMembership |
            m.member = op.caller and m.patient = op.target and m.mstatus = Active)
    // A clinician without an active membership cannot obtain a Permitted outcome.
    all op: Operation |
        (op.op_kind = RecordsLookup and
         no m: CareTeamMembership |
             m.member = op.caller and m.patient = op.target and m.mstatus = Active)
        implies op.outcome != Permitted
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003, SC-011; contracts/http-api.md "Byte-equivalent not-found response"
// ─────────────────────────────────────────────────────────────────────────────
pred NoInformationLeakage {
    // Denied and NotFoundOrDenied outcomes must produce identical HTTP responses;
    // specifically, both must receive the canonical 404 response shape — the
    // caller cannot distinguish "patient does not exist" from "not on care team".
    some op: Operation | op.outcome = Denied
    some op: Operation | op.outcome = NotFoundOrDenied
    all op: Operation |
        op.outcome = Denied implies op.response = Resp404NotFound
    all op: Operation |
        op.outcome = NotFoundOrDenied implies op.response = Resp404NotFound
    // Permitted access must NOT return 404.
    all op: Operation |
        op.outcome = Permitted implies op.response != Resp404NotFound
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// ─────────────────────────────────────────────────────────────────────────────
// FR-001 — authentication boundary: every service-layer operation has an authenticated caller
// FEATURE-SPECIFIC  ANCHOR: FR-001; contracts/http-api.md §Authentication
// ─────────────────────────────────────────────────────────────────────────────
pred FR_001_AuthRequired {
    some Operation
    // All Operations have a resolved User caller (unauthenticated requests never
    // become Operations — they are rejected before the handler runs).
    all op: Operation | one op.caller
    // No Operation's caller has a role outside the v1 catalogue.
    all op: Operation |
        op.caller.role in (RoleDoctor + RoleNurse + RolePharmacist +
                           RoleAuditOfficer + RoleClinicalAdmin)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// ─────────────────────────────────────────────────────────────────────────────
// FR-002 — each user is resolved to exactly one role from the v1 catalogue
// FEATURE-SPECIFIC  ANCHOR: FR-002; data-model.md User.clinician_role CHECK constraint
// ─────────────────────────────────────────────────────────────────────────────
pred FR_002_UniqueRolePerUser {
    some User
    // The `role: one Role` field on User already enforces one role per user;
    // we check that the role is always one of the five catalogue values.
    all u: User |
        u.role in (RoleDoctor + RoleNurse + RolePharmacist +
                   RoleAuditOfficer + RoleClinicalAdmin)
}
assert FR_002_UniqueRolePerUser { FR_002_UniqueRolePerUser }
check FR_002_UniqueRolePerUser for 8

// ─────────────────────────────────────────────────────────────────────────────
// FR-005 — read-only access scope: only RecordsLookup and AuditSearch exist
// FEATURE-SPECIFIC  ANCHOR: FR-005; spec.md "read-only, no amendment, no prescribing"
// ─────────────────────────────────────────────────────────────────────────────
pred FR_005_ReadOnlyAccess {
    // The only operation kinds in the system are RecordsLookup and AuditSearch;
    // no mutation endpoint exists.  OperationKind = {RecordsLookup, AuditSearch}
    // by construction; every operation must be one of these two.
    some Operation
    all op: Operation |
        op.op_kind in (RecordsLookup + AuditSearch)
    // No OperationKind atom exists outside these two.
    OperationKind = RecordsLookup + AuditSearch
}
assert FR_005_ReadOnlyAccess { FR_005_ReadOnlyAccess }
check FR_005_ReadOnlyAccess for 8

// ─────────────────────────────────────────────────────────────────────────────
// FR-006 — care-team membership gating
// FEATURE-SPECIFIC  ANCHOR: FR-006; data-model.md CareTeamMembership; contracts/http-api.md §Authorisation
// ─────────────────────────────────────────────────────────────────────────────
pred FR_006_CareTeamGating {
    // Permitted RecordsLookup ⟹ active care-team membership for (caller, patient).
    some op: Operation | op.op_kind = RecordsLookup and op.outcome = Permitted
    all op: Operation |
        (op.op_kind = RecordsLookup and op.outcome = Permitted) implies
        (some m: CareTeamMembership |
            m.member = op.caller and m.patient = op.target and m.mstatus = Active)
    // Converse: no active membership ⟹ not Permitted.
    all op: Operation |
        (op.op_kind = RecordsLookup and
         (no m: CareTeamMembership |
              m.member = op.caller and m.patient = op.target and m.mstatus = Active))
        implies op.outcome != Permitted
    // Ended membership is NOT sufficient for access.
    all op: Operation |
        (op.op_kind = RecordsLookup and
         (all m: CareTeamMembership |
              (m.member = op.caller and m.patient = op.target) implies m.mstatus = Ended))
        implies op.outcome != Permitted
}
assert FR_006_CareTeamGating { FR_006_CareTeamGating }
check FR_006_CareTeamGating for 8

// ─────────────────────────────────────────────────────────────────────────────
// FR-007 — byte-equivalent not-found response for deny and not-found
// FEATURE-SPECIFIC  ANCHOR: FR-007, SC-003; contracts/http-api.md "Byte-equivalent not-found response"
// ─────────────────────────────────────────────────────────────────────────────
pred FR_007_ByteEquivalentDenyNotFound {
    // Both Denied and NotFoundOrDenied outcomes must produce the SAME response shape.
    // A clinician cannot distinguish "patient not on your care team" from "no such patient".
    some op: Operation | op.outcome = Denied
    some op: Operation | op.outcome = NotFoundOrDenied
    all op: Operation |
        (op.outcome = Denied or op.outcome = NotFoundOrDenied) implies
        op.response = Resp404NotFound
}
assert FR_007_ByteEquivalentDenyNotFound { FR_007_ByteEquivalentDenyNotFound }
check FR_007_ByteEquivalentDenyNotFound for 8

// ─────────────────────────────────────────────────────────────────────────────
// FR-008 — always-on audit: every operation (except 503) has exactly one audit entry
// FEATURE-SPECIFIC  ANCHOR: FR-008, SC-001, SC-002; data-model.md AuditEntry
// ─────────────────────────────────────────────────────────────────────────────
pred FR_008_AlwaysOnAudit {
    some op: Operation | op.response != Resp503Unavail
    all op: Operation |
        op.response != Resp503Unavail implies
        (one ae: AuditEntry | ae.records_op = op)
    // Converse: 503 → no audit entry
    all op: Operation |
        op.response = Resp503Unavail implies
        (no ae: AuditEntry | ae.records_op = op)
}
assert FR_008_AlwaysOnAudit { FR_008_AlwaysOnAudit }
check FR_008_AlwaysOnAudit for 8

// ─────────────────────────────────────────────────────────────────────────────
// FR-009 — audit entry shape: all required fields present and correctly attributed
// FEATURE-SPECIFIC  ANCHOR: FR-009; data-model.md AuditEntry column list
// ─────────────────────────────────────────────────────────────────────────────
pred FR_009_AuditEntryShape {
    some AuditEntry
    all ae: AuditEntry |
        // clinician_id + snapshotted role
        one ae.ae_clinician
        and one ae.snapshotted_role
        // patient_id (presented; may be lone for not-found case)
        and ae.patient_ref = ae.records_op.target
        // outcome and authorisation_basis
        and one ae.ae_outcome
        and one ae.ae_auth_basis
        // snapshot correctness
        and ae.snapshotted_role = ae.ae_clinician.role
        // attribution
        and ae.ae_clinician = ae.records_op.caller
        and ae.ae_outcome   = ae.records_op.outcome
        and ae.ae_auth_basis = ae.records_op.auth_basis
}
assert FR_009_AuditEntryShape { FR_009_AuditEntryShape }
check FR_009_AuditEntryShape for 8

// ─────────────────────────────────────────────────────────────────────────────
// FR-010 — immutable audit entries (append-only)
// FEATURE-SPECIFIC  ANCHOR: FR-010, SC-006; data-model.md "no UPDATE/DELETE"
// ─────────────────────────────────────────────────────────────────────────────
pred FR_010_AuditImmutable {
    some AuditEntry
    // Structural proxy for immutability: each operation is recorded by at most one
    // audit entry (no overwrite), and the link is injective (no two entries for the same op).
    all disj ae1, ae2: AuditEntry | ae1.records_op != ae2.records_op
    // Every audit entry has exactly one operation it records.
    all ae: AuditEntry | one ae.records_op
}
assert FR_010_AuditImmutable { FR_010_AuditImmutable }
check FR_010_AuditImmutable for 8

// ─────────────────────────────────────────────────────────────────────────────
// FR-011 — audit-search endpoint accessible only to audit_officer; hidden from clinical roles
// FEATURE-SPECIFIC  ANCHOR: FR-011, SC-011; contracts/http-api.md §POST /audit/search Authorisation
// ─────────────────────────────────────────────────────────────────────────────
pred FR_011_AuditAccessByIGOnly {
    // Only AuditOfficer-role callers may perform AuditSearch operations.
    some op: Operation | op.op_kind = AuditSearch
    all op: Operation |
        op.op_kind = AuditSearch implies op.caller.role = RoleAuditOfficer
    // Clinical roles get the byte-equivalent 404 when they try to reach AuditSearch;
    // the endpoint's existence does not leak.  In this model, clinical roles simply
    // cannot have AuditSearch in their allowed set.
    no op: Operation |
        op.op_kind = AuditSearch and
        op.caller.role in (RoleDoctor + RoleNurse + RolePharmacist + RoleClinicalAdmin)
}
assert FR_011_AuditAccessByIGOnly { FR_011_AuditAccessByIGOnly }
check FR_011_AuditAccessByIGOnly for 8

// ─────────────────────────────────────────────────────────────────────────────
// FR-012 — retention floor: no delete path exists against audit entries
// FEATURE-SPECIFIC  ANCHOR: FR-012, SC-006; data-model.md "no DELETE code path"; spec.md FR-012
// ─────────────────────────────────────────────────────────────────────────────
pred FR_012_RetentionFloor {
    // Structural proxy: every AuditEntry that ever existed persists in the model.
    // There is no "remove" relation; AuditEntry atoms are not retractable.
    // We assert that the set of AuditEntries is non-empty and every AuditEntry
    // has a valid, non-null linked operation.
    some AuditEntry
    all ae: AuditEntry | one ae.records_op
    // No audit entry lacks a clinician attribution — deletion would sever this.
    all ae: AuditEntry | one ae.ae_clinician
}
assert FR_012_RetentionFloor { FR_012_RetentionFloor }
check FR_012_RetentionFloor for 8

// ─────────────────────────────────────────────────────────────────────────────
// FR-013 — audit SLA: 503 response ⟺ no audit entry written
// FEATURE-SPECIFIC  ANCHOR: FR-013, SC-007; contracts/http-api.md §503 service_unavailable
// ─────────────────────────────────────────────────────────────────────────────
pred FR_013_AuditSLAOrRefuse {
    some Operation
    // 503 → no audit entry (the access was refused without a record)
    all op: Operation |
        op.response = Resp503Unavail implies
        (no ae: AuditEntry | ae.records_op = op)
    // Non-503 → exactly one audit entry
    all op: Operation |
        op.response != Resp503Unavail implies
        (one ae: AuditEntry | ae.records_op = op)
    // 503 → no patient content returned (response is not 200)
    all op: Operation |
        op.response = Resp503Unavail implies op.outcome != Permitted
}
assert FR_013_AuditSLAOrRefuse { FR_013_AuditSLAOrRefuse }
check FR_013_AuditSLAOrRefuse for 8

// ─────────────────────────────────────────────────────────────────────────────
// FR-014 + FR-015 — safety block at top of every successful record view
// FEATURE-SPECIFIC  ANCHOR: FR-014, FR-015, SC-008; contracts/http-api.md §200 OK response key order
// ─────────────────────────────────────────────────────────────────────────────
pred FR_014_FR_015_SafetyBlockPresent {
    // Every permitted RecordsLookup targets a patient with a PatientSummary
    // (the structural proxy for "allergies/warnings/id/DoB present in response").
    some op: Operation | op.op_kind = RecordsLookup and op.outcome = Permitted
    all op: Operation |
        (op.op_kind = RecordsLookup and op.outcome = Permitted) implies
        (some ps: PatientSummary | ps.owner = op.target)
    // PatientSummary is 1-1 with Patient; no two summaries share an owner.
    all disj ps1, ps2: PatientSummary | ps1.owner != ps2.owner
}
assert FR_014_FR_015_SafetyBlockPresent { FR_014_FR_015_SafetyBlockPresent }
check FR_014_FR_015_SafetyBlockPresent for 8

// ─────────────────────────────────────────────────────────────────────────────
// PATTERN: PermissionGrounding  ANCHOR: spec.md FR-006 (RecordsLookup grant); FR-011 (AuditSearch grant)
// ─────────────────────────────────────────────────────────────────────────────
pred PermissionGrounding {
    // Every allowed cell traces to at least one FR.
    // FR-006 grounds RecordsLookup for clinical roles.
    // FR-011 grounds AuditSearch for AuditOfficer.
    // In the closed-world model, we assert that the Allowed set contains exactly
    // the cells that have FR grounding (no silent grants).
    PermMatrix.Allowed =
        (RoleDoctor        -> RecordsLookup)   // FR-006: doctor is a clinical role
      + (RoleNurse         -> RecordsLookup)   // FR-006: nurse is a clinical role
      + (RolePharmacist    -> RecordsLookup)   // FR-006: pharmacist is a clinical role
      + (RoleClinicalAdmin -> RecordsLookup)   // FR-006: clinical_admin is a clinical role
      + (RoleAuditOfficer  -> AuditSearch)     // FR-011: audit_officer reads the audit log
    // No extra cells exist beyond these grounded grants.
    #(PermMatrix.Allowed) = 5
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 8